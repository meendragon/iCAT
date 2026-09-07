// SPDX-License-Identifier: GPL-2.0-only

#include <linux/vmalloc.h>
#include <linux/slab.h>
#include <linux/ktime.h>
#include <linux/math64.h>
#include <linux/sched/clock.h>
#include <linux/time64.h>
#include <linux/string.h>

#include "nvmev.h"
#include "conv_ftl.h"

/*
 * WA-AT GC v2: the original experimental staircase grid is now an online
 * action space.  No experimental WAF values or artificial pulls are seeded.
 * The CAT score, invalidation clock and FTL data path retain their meaning.
 */
static void watgc_v2_decode(uint32_t arm, uint32_t *k,
			   uint32_t *scale_pct, uint32_t *age_ratio)
{
	static const uint32_t levels[WATGC_V2_K_N] = { 2, 4, 7, 10 };
	static const uint32_t scales[WATGC_V2_SCALE_N] = { 25, 50, 100, 200, 400 };
	static const uint32_t ratios[WATGC_V2_RATIO_N] = { 4, 7, 16 };

	NVMEV_ASSERT(arm < WATGC_V2_ARM_N);
	*age_ratio = ratios[arm % WATGC_V2_RATIO_N];
	arm /= WATGC_V2_RATIO_N;
	*scale_pct = scales[arm % WATGC_V2_SCALE_N];
	*k = levels[arm / WATGC_V2_SCALE_N];
}

static void watgc_v2_set_arm(struct conv_ftl *ftl, uint32_t arm)
{
	/* Thresholds in thirds of a second; scale BEFORE rounding to ns. */
	static const uint32_t threshold_thirds[WATGC_V2_K_N][9] = {
		{ 1080 },
		{ 60, 270, 1080 },
		{ 30, 60, 135, 270, 540, 1080 },
		{ 20, 40, 60, 110, 180, 270, 450, 720, 1080 },
	};
	struct watgc_v2_param *p = &ftl->tuner.param;
	uint32_t ki = arm / (WATGC_V2_SCALE_N * WATGC_V2_RATIO_N);
	uint32_t i;

	watgc_v2_decode(arm, &p->k, &p->scale_pct, &p->age_ratio);
	ftl->tuner.current_arm = arm;
	memset(p->threshold_ns, 0, sizeof(p->threshold_ns));
	memset(p->age_value, 0, sizeof(p->age_value));
	for (i = 0; i + 1 < p->k; i++)
		p->threshold_ns[i] =
			div64_u64((uint64_t)threshold_thirds[ki][i] *
				  NSEC_PER_SEC * p->scale_pct, 300ULL);
	for (i = 0; i < p->k; i++)
		p->age_value[i] = 18U + (p->age_ratio - 1U) * 18U * i / (p->k - 1U);
}

static uint32_t __maybe_unused
cat_fig7_transform_age(const struct watgc_v2_param *p,
		      const struct line *line, uint64_t now_ns)
{
	uint64_t age_ns;
	uint32_t i;

	if (!line->last_invalidated_at_ns || now_ns < line->last_invalidated_at_ns)
		return p->age_value[0];
	age_ns = now_ns - line->last_invalidated_at_ns;
	for (i = 0; i + 1 < p->k; i++)
		if (age_ns < p->threshold_ns[i])
			return p->age_value[i];
	return p->age_value[p->k - 1U];
}

/* Exact rational comparison, including geometries that overflow cross products. */
static int __maybe_unused
watgc_v2_fraction_cmp(uint64_t an, uint64_t ad, uint64_t bn, uint64_t bd)
{
	bool reverse = false;

	NVMEV_ASSERT(ad && bd);
	if ((!an || bd <= (~0ULL / an)) && (!bn || ad <= (~0ULL / bn))) {
		uint64_t left = an * bd;
		uint64_t right = bn * ad;

		return left < right ? -1 : (left > right ? 1 : 0);
	}
	for (;;) {
		uint64_t ar, br;
		uint64_t aq = div64_u64_rem(an, ad, &ar);
		uint64_t bq = div64_u64_rem(bn, bd, &br);
		int cmp;

		if (aq != bq) {
			cmp = aq < bq ? -1 : 1;
			return reverse ? -cmp : cmp;
		}
		if (!ar || !br) {
			cmp = !ar ? (!br ? 0 : -1) : 1;
			return reverse ? -cmp : cmp;
		}
		an = ad;
		ad = ar;
		bn = bd;
		bd = br;
		reverse = !reverse;
	}
}

/* Lower vpc / (ipc * staircase_age) is better; no erase-count input. */
static bool __maybe_unused
cat_fig7_line_is_better(const struct watgc_v2_param *p,
		       const struct line *candidate, const struct line *best_line,
		       uint64_t now_ns)
{
	uint64_t candidate_den, best_den;
	int cmp;

	NVMEV_ASSERT(candidate->ipc > 0 && best_line->ipc > 0);
	candidate_den = (uint64_t)candidate->ipc *
			cat_fig7_transform_age(p, candidate, now_ns);
	best_den = (uint64_t)best_line->ipc *
		   cat_fig7_transform_age(p, best_line, now_ns);
	cmp = watgc_v2_fraction_cmp(candidate->vpc, candidate_den,
				    best_line->vpc, best_den);
	return cmp < 0 || (cmp == 0 && candidate->id < best_line->id);
}

static const char *conv_gc_policy_name(void)
{
#if CONV_GC_POLICY == CONV_GC_POLICY_GREEDY
	return "greedy";
#elif CONV_GC_POLICY == CONV_GC_POLICY_CAT_FIG7
	return "cat-fig7-fixed";
#else
	return "watgc-v2";
#endif
}

/* WATGC_V2_CORE_BEGIN */
#if CONV_GC_POLICY == CONV_GC_POLICY_WATGC_V2
/*
 * Online, globally exploring discounted bandit.  Confidence bonuses and the
 * settled flag are engineering heuristics: a stateful SSD is not an iid
 * bandit, and neither proves a global optimum or eliminates policy carryover.
 */
static bool watgc_v2_waf_q16(uint64_t host, uint64_t gc, uint32_t *out)
{
	uint64_t whole, rem, fraction = 0;
	uint32_t i;

	if (!host)
		return false;
	whole = div64_u64_rem(gc, host, &rem);
	if (whole >= 65535ULL)
		return false;
	/* Binary long division avoids overflowing rem << 16. */
	for (i = 0; i < WATGC_V2_Q; i++) {
		fraction <<= 1;
		if (rem >= host - rem) {
			rem -= host - rem;
			fraction |= 1;
		} else {
			rem += rem;
		}
	}
	*out = (uint32_t)(((whole + 1) << WATGC_V2_Q) | fraction);
	return true;
}

static uint64_t watgc_v2_discount(uint64_t value)
{
	return (value >> WATGC_V2_Q) * WATGC_V2_GAMMA_Q16 +
	       (((value & (WATGC_V2_ONE - 1)) * WATGC_V2_GAMMA_Q16) >>
		WATGC_V2_Q);
}

static uint64_t watgc_v2_sqrt(uint64_t value)
{
	uint64_t root = 0, bit = 1ULL << 62;

	while (bit > value)
		bit >>= 2;
	while (bit) {
		if (value >= root + bit) {
			value -= root + bit;
			root = (root >> 1) + bit;
		} else {
			root >>= 1;
		}
		bit >>= 2;
	}
	return root;
}

/* ln(count), Q16; normalize then use the first three atanh-series terms. */
static uint64_t watgc_v2_log_q16(uint64_t count_q16)
{
	uint64_t integral = 0, z, z2, z3, z5;

	if (count_q16 <= WATGC_V2_ONE)
		return 0;
	while (count_q16 >= 2 * WATGC_V2_ONE) {
		count_q16 >>= 1;
		integral += 45426; /* ln(2) in Q16 */
	}
	z = div64_u64((count_q16 - WATGC_V2_ONE) * WATGC_V2_ONE,
		      count_q16 + WATGC_V2_ONE);
	z2 = (z * z) >> WATGC_V2_Q;
	z3 = (z2 * z) >> WATGC_V2_Q;
	z5 = (z3 * z2) >> WATGC_V2_Q;
	return integral + 2 * (z + div64_u64(z3, 3) + div64_u64(z5, 5));
}

static void watgc_v2_begin_phase(struct conv_ftl *ftl,
				enum watgc_v2_phase phase, uint64_t now_ns)
{
	struct watgc_v2_tuner *t = &ftl->tuner;

	t->phase = phase;
	t->phase_host_start = ftl->stats.total_host_page_writes;
	t->phase_gcpage_start = ftl->stats.total_gc_page_writes;
	t->phase_gc_start = ftl->stats.total_gc_count;
	t->phase_start_ns = now_ns;
}

static uint32_t watgc_v2_oldest(const struct watgc_v2_tuner *t, bool omit_best)
{
	uint32_t i, oldest = WATGC_V2_ARM_N;

	for (i = 0; i < WATGC_V2_ARM_N; i++) {
		if (omit_best && i == t->best_arm)
			continue;
		if (oldest == WATGC_V2_ARM_N ||
		    t->arm[i].last_window < t->arm[oldest].last_window)
			oldest = i;
	}
	return oldest;
}

static bool watgc_v2_covered(const struct watgc_v2_tuner *t)
{
	uint32_t i;

	for (i = 0; i < WATGC_V2_ARM_N; i++) {
		if (t->arm[i].visits < WATGC_V2_MIN_VISITS)
			return false;
	}
	return true;
}

static uint32_t watgc_v2_choose_search(const struct watgc_v2_tuner *t)
{
	uint64_t total = 0, log_total, ratio, bonus;
	uint32_t i, choice = 0, oldest;
	uint32_t mean;
	int64_t score, lowest = 0;
	bool have_score = false;

	/* Three real observations per arm, with deterministic balanced coverage. */
	for (i = 1; i < WATGC_V2_ARM_N; i++) {
		if (t->arm[i].visits < t->arm[choice].visits)
			choice = i;
	}
	if (t->arm[choice].visits < WATGC_V2_MIN_VISITS)
		return choice;
	oldest = watgc_v2_oldest(t, false);
	if (t->windows - t->arm[oldest].last_window >= WATGC_V2_STALE_WINDOWS)
		return oldest;
	for (i = 0; i < WATGC_V2_ARM_N; i++) {
		if (!t->arm[i].count_q16 ||
		    !watgc_v2_waf_q16(t->arm[i].host_pages,
				     t->arm[i].gc_pages, &mean))
			return i;
		if (~0ULL - total < t->arm[i].count_q16)
			total = ~0ULL;
		else
			total += t->arm[i].count_q16;
	}
	log_total = watgc_v2_log_q16(total);
	for (i = 0; i < WATGC_V2_ARM_N; i++) {
		watgc_v2_waf_q16(t->arm[i].host_pages, t->arm[i].gc_pages, &mean);
		ratio = div64_u64(2 * log_total * WATGC_V2_ONE,
				  t->arm[i].count_q16);
		bonus = (WATGC_V2_UCB_C_Q16 *
			 watgc_v2_sqrt(ratio * WATGC_V2_ONE)) >> WATGC_V2_Q;
		score = (int64_t)mean - (int64_t)bonus;
		if (!have_score || score < lowest) {
			choice = i;
			lowest = score;
			have_score = true;
		}
	}
	return choice;
}

static void watgc_v2_reset_epoch(struct conv_ftl *ftl, uint32_t sample_waf)
{
	struct watgc_v2_tuner *t = &ftl->tuner;
	uint32_t i;

	NVMEV_INFO("WATGC_V2 reset ns=%u part=%u epoch=%llu window=%llu "
		   "arm=%u reason=waf-drift reference_q16=%u sample_q16=%u\n",
		   t->ns_id, t->part_id, t->epoch, t->windows,
		   t->current_arm, t->reference_waf_q16, sample_waf);
	for (i = 0; i < WATGC_V2_ARM_N; i++)
		t->arm[i] = (struct watgc_v2_arm){ 0 };
	t->epoch++;
	t->epoch_windows = 0;
	t->best_arm = t->current_arm;
	t->stable_windows = 0;
	t->best_confirmations = 0;
	t->exploit_windows = 0;
	t->drift_windows = 0;
	t->reference_waf_q16 = 0;
	t->settled = false;
}

static void watgc_v2_update_best(struct conv_ftl *ftl)
{
	struct watgc_v2_tuner *t = &ftl->tuner;
	uint32_t i, candidate = t->best_arm, mean, minimum = ~0U, incumbent;
	bool had_incumbent;

	had_incumbent = watgc_v2_waf_q16(t->arm[t->best_arm].host_pages,
					 t->arm[t->best_arm].gc_pages, &incumbent);
	for (i = 0; i < WATGC_V2_ARM_N; i++) {
		if (!t->arm[i].visits ||
		    !watgc_v2_waf_q16(t->arm[i].host_pages, t->arm[i].gc_pages, &mean))
			continue;
		if (mean < minimum) {
			minimum = mean;
			candidate = i;
		}
	}
	/* Retain the incumbent unless the alternative improves by over 0.5%. */
	if (had_incumbent && candidate != t->best_arm &&
	    (incumbent <= minimum ||
	     (uint64_t)(incumbent - minimum) * WATGC_V2_ONE <=
	     (uint64_t)incumbent * WATGC_V2_TOLERANCE_Q16))
		candidate = t->best_arm;
	if (candidate != t->best_arm) {
		t->best_arm = candidate;
		t->stable_windows = 0;
		t->best_confirmations = 0;
		t->exploit_windows = 0;
		t->drift_windows = 0;
		t->reference_waf_q16 = 0;
		t->settled = false;
	} else if (t->stable_windows != ~0U) {
		t->stable_windows++;
	}
	if (t->current_arm == t->best_arm && t->best_confirmations != ~0U)
		t->best_confirmations++;
	if (!t->settled && watgc_v2_covered(t) &&
	    t->stable_windows >= WATGC_V2_STABLE_WINDOWS &&
	    t->best_confirmations >= WATGC_V2_BEST_CONFIRMATIONS) {
		t->settled = true;
		t->exploit_windows = 0;
		t->drift_windows = 0;
		watgc_v2_waf_q16(t->arm[t->best_arm].host_pages,
				 t->arm[t->best_arm].gc_pages, &t->reference_waf_q16);
		NVMEV_INFO("WATGC_V2 settled ns=%u part=%u epoch=%llu window=%llu "
			   "best=%u waf_q16=%u meaning=empirical-stability\n",
			   t->ns_id, t->part_id, t->epoch, t->windows,
			   t->best_arm, t->reference_waf_q16);
	}
}

static uint32_t watgc_v2_observe(struct conv_ftl *ftl, uint64_t host,
				uint64_t gc_pages, uint32_t sample_waf)
{
	struct watgc_v2_tuner *t = &ftl->tuner;
	struct watgc_v2_arm *a;
	uint64_t delta, weighted_host = host << WATGC_V2_Q;
	uint64_t weighted_gc = gc_pages << WATGC_V2_Q;
	uint32_t i;
	bool had_coverage, first_coverage;

	t->windows++;
	if (t->settled && t->current_arm == t->best_arm) {
		delta = sample_waf > t->reference_waf_q16 ?
			sample_waf - t->reference_waf_q16 :
			t->reference_waf_q16 - sample_waf;
		if (delta * WATGC_V2_ONE >
		    (uint64_t)t->reference_waf_q16 * WATGC_V2_DRIFT_Q16)
			t->drift_windows++;
		else
			t->drift_windows = 0;
		if (t->drift_windows >= WATGC_V2_DRIFT_WINDOWS)
			watgc_v2_reset_epoch(ftl, sample_waf);
	}
	had_coverage = watgc_v2_covered(t);
	t->epoch_windows++;
	for (i = 0; i < WATGC_V2_ARM_N; i++) {
		a = &t->arm[i];
		a->host_pages = watgc_v2_discount(a->host_pages);
		a->gc_pages = watgc_v2_discount(a->gc_pages);
		a->count_q16 = watgc_v2_discount(a->count_q16);
	}
	a = &t->arm[t->current_arm];
	/* Preserve paired sums if exceptionally long counters need rescaling. */
	while (~0ULL - a->host_pages < weighted_host ||
	       ~0ULL - a->gc_pages < weighted_gc ||
	       ~0ULL - a->count_q16 < WATGC_V2_ONE) {
		a->host_pages >>= 1;
		a->gc_pages >>= 1;
		a->count_q16 >>= 1;
	}
	/* Q16 page sums retain fractional pages during every discount step. */
	a->host_pages += weighted_host;
	a->gc_pages += weighted_gc;
	a->count_q16 += WATGC_V2_ONE;
	if (a->visits != ~0ULL)
		a->visits++;
	a->last_window = t->windows;
	first_coverage = !had_coverage && watgc_v2_covered(t);
	if (first_coverage) {
		t->stable_windows = 0;
		t->best_confirmations = 0;
	}
	watgc_v2_update_best(ftl);
	/* Bootstrap observations do not establish post-coverage stability. */
	if (first_coverage) {
		t->stable_windows = 0;
		t->best_confirmations = 0;
	}
	if (!t->settled)
		return watgc_v2_choose_search(t);
	/* Every eight incumbent observations, validate the oldest other arm. */
	if (t->current_arm != t->best_arm) {
		t->exploit_windows = 0;
		return t->best_arm;
	}
	if (++t->exploit_windows >= WATGC_V2_PROBE_EVERY) {
		t->exploit_windows = 0;
		return watgc_v2_oldest(t, true);
	}
	return t->best_arm;
}

static void watgc_v2_init(struct conv_ftl *ftl, uint32_t ns_id, uint32_t part_id)
{
	struct watgc_v2_tuner *t = &ftl->tuner;

	memset(t, 0, sizeof(*t));
	t->ns_id = ns_id;
	t->part_id = part_id;
	t->epoch = 1;
	t->best_arm = WATGC_V2_INITIAL_ARM;
	watgc_v2_set_arm(ftl, WATGC_V2_INITIAL_ARM);
	t->phase = WATGC_V2_WARMUP;
	NVMEV_INFO("WATGC_V2 init ns=%u part=%u arms=%u initial=%u "
		   "prior=none gamma_q16=%llu exploration_q16=%llu\n",
		   ns_id, part_id, WATGC_V2_ARM_N, t->current_arm,
		   WATGC_V2_GAMMA_Q16, WATGC_V2_UCB_C_Q16);
}

static void watgc_v2_on_gc(struct conv_ftl *ftl, uint64_t now_ns)
{
	struct watgc_v2_tuner *t = &ftl->tuner;
	uint64_t host, gc_pages, gc_count;
	uint32_t sample, evaluated, next, k, scale, ratio;
	bool ready;

	if (t->phase == WATGC_V2_WARMUP) {
		if (ftl->stats.total_gc_count >= WATGC_V2_WARMUP_GC) {
			watgc_v2_begin_phase(ftl, WATGC_V2_BURNIN, now_ns);
			NVMEV_INFO("WATGC_V2 warmup-done ns=%u part=%u gc_count=%llu\n",
				   t->ns_id, t->part_id, ftl->stats.total_gc_count);
		}
		return;
	}
	host = ftl->stats.total_host_page_writes - t->phase_host_start;
	gc_pages = ftl->stats.total_gc_page_writes - t->phase_gcpage_start;
	gc_count = ftl->stats.total_gc_count - t->phase_gc_start;
	if (t->phase == WATGC_V2_BURNIN)
		ready = host >= WATGC_V2_BURNIN_HOST_PAGES &&
			gc_count >= WATGC_V2_BURNIN_GC;
	else
		ready = host >= WATGC_V2_WINDOW_HOST_PAGES &&
			gc_count >= WATGC_V2_WINDOW_GC;
	if (!ready) {
		if (gc_count < WATGC_V2_MAX_WINDOW_GC &&
		    (now_ns < t->phase_start_ns ||
		     now_ns - t->phase_start_ns < WATGC_V2_MAX_WINDOW_NS))
			return;
		t->discarded_windows++;
		NVMEV_INFO("WATGC_V2 discard ns=%u part=%u epoch=%llu phase=%u "
			   "arm=%u host=%llu gc_pages=%llu gc_count=%llu reason=undersized\n",
			   t->ns_id, t->part_id, t->epoch, (uint32_t)t->phase,
			   t->current_arm, host, gc_pages, gc_count);
		watgc_v2_begin_phase(ftl, WATGC_V2_BURNIN, now_ns);
		return;
	}
	if (t->phase == WATGC_V2_BURNIN) {
		watgc_v2_begin_phase(ftl, WATGC_V2_MEASURE, now_ns);
		return;
	}
	if (host > (~0ULL >> WATGC_V2_Q) ||
	    gc_pages > (~0ULL >> WATGC_V2_Q) ||
	    !watgc_v2_waf_q16(host, gc_pages, &sample)) {
		t->discarded_windows++;
		NVMEV_INFO("WATGC_V2 discard ns=%u part=%u epoch=%llu "
			   "arm=%u host=%llu gc_pages=%llu reason=numeric-range\n",
			   t->ns_id, t->part_id, t->epoch, t->current_arm, host, gc_pages);
		watgc_v2_begin_phase(ftl, WATGC_V2_BURNIN, now_ns);
		return;
	}
	evaluated = t->current_arm;
	watgc_v2_decode(evaluated, &k, &scale, &ratio);
	next = watgc_v2_observe(ftl, host, gc_pages, sample);
	NVMEV_INFO("WATGC_V2 sample ns=%u part=%u epoch=%llu window=%llu "
		   "phase=measure evaluated=%u k=%u scale_pct=%u age_ratio=%u "
		   "host=%llu gc_pages=%llu gc_count=%llu waf_q16=%u "
		   "best=%u next=%u settled=%u\n",
		   t->ns_id, t->part_id, t->epoch, t->windows,
		   evaluated, k, scale, ratio, host, gc_pages, gc_count, sample,
		   t->best_arm, next, (uint32_t)t->settled);
	if (next != evaluated) {
		watgc_v2_set_arm(ftl, next);
		watgc_v2_begin_phase(ftl, WATGC_V2_BURNIN, now_ns);
	} else {
		watgc_v2_begin_phase(ftl, WATGC_V2_MEASURE, now_ns);
	}
}

static void watgc_v2_report(struct conv_ftl *ftl)
{
	struct watgc_v2_tuner *t = &ftl->tuner;
	uint32_t k, scale, ratio, mean = 0, i, visited = 0;
	bool valid;

	for (i = 0; i < WATGC_V2_ARM_N; i++) {
		if (t->arm[i].visits)
			visited++;
	}
	valid = watgc_v2_waf_q16(t->arm[t->best_arm].host_pages,
				t->arm[t->best_arm].gc_pages, &mean);
	watgc_v2_decode(t->best_arm, &k, &scale, &ratio);
	NVMEV_INFO("WATGC_V2 summary ns=%u part=%u epoch=%llu windows=%llu "
		   "epoch_windows=%llu discarded=%llu visited=%u covered=%u "
		   "settled=%u phase=%u current=%u best=%u k=%u scale_pct=%u "
		   "age_ratio=%u best_waf_valid=%u best_waf_q16=%u\n",
		   t->ns_id, t->part_id, t->epoch, t->windows,
		   t->epoch_windows, t->discarded_windows, visited,
		   (uint32_t)watgc_v2_covered(t), (uint32_t)t->settled,
		   (uint32_t)t->phase, t->current_arm, t->best_arm, k, scale, ratio,
		   (uint32_t)valid, mean);
}
#else
static void watgc_v2_init(struct conv_ftl *ftl, uint32_t ns_id, uint32_t part_id)
{
	memset(&ftl->tuner, 0, sizeof(ftl->tuner));
	ftl->tuner.ns_id = ns_id;
	ftl->tuner.part_id = part_id;
	ftl->tuner.best_arm = WATGC_V2_INITIAL_ARM;
	watgc_v2_set_arm(ftl, WATGC_V2_INITIAL_ARM);
}

static void watgc_v2_on_gc(struct conv_ftl *ftl, uint64_t now_ns)
{
	(void)ftl;
	(void)now_ns;
}

static void watgc_v2_report(struct conv_ftl *ftl)
{
	(void)ftl;
}
#endif /* CONV_GC_POLICY_WATGC_V2 */
/* WATGC_V2_CORE_END */

static inline bool last_pg_in_wordline(struct conv_ftl *conv_ftl, struct ppa *ppa)
{
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	return (ppa->g.pg % spp->pgs_per_oneshotpg) == (spp->pgs_per_oneshotpg - 1);
}

static bool should_gc(struct conv_ftl *conv_ftl)
{
	return (conv_ftl->lm.free_line_cnt <= conv_ftl->cp.gc_thres_lines);
}

static inline bool should_gc_high(struct conv_ftl *conv_ftl)
{
	return conv_ftl->lm.free_line_cnt <= conv_ftl->cp.gc_thres_lines_high;
}

static inline struct ppa get_maptbl_ent(struct conv_ftl *conv_ftl, uint64_t lpn)
{
	return conv_ftl->maptbl[lpn];
}

static inline void set_maptbl_ent(struct conv_ftl *conv_ftl, uint64_t lpn, struct ppa *ppa)
{
	NVMEV_ASSERT(lpn < conv_ftl->ssd->sp.tt_pgs);
	conv_ftl->maptbl[lpn] = *ppa;
}

static uint64_t ppa2pgidx(struct conv_ftl *conv_ftl, struct ppa *ppa)
{
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	uint64_t pgidx;

	NVMEV_DEBUG_VERBOSE("%s: ch:%d, lun:%d, pl:%d, blk:%d, pg:%d\n", __func__,
			ppa->g.ch, ppa->g.lun, ppa->g.pl, ppa->g.blk, ppa->g.pg);

	pgidx = ppa->g.ch * spp->pgs_per_ch + ppa->g.lun * spp->pgs_per_lun +
		ppa->g.pl * spp->pgs_per_pl + ppa->g.blk * spp->pgs_per_blk + ppa->g.pg;

	NVMEV_ASSERT(pgidx < spp->tt_pgs);

	return pgidx;
}

static inline uint64_t get_rmap_ent(struct conv_ftl *conv_ftl, struct ppa *ppa)
{
	uint64_t pgidx = ppa2pgidx(conv_ftl, ppa);

	return conv_ftl->rmap[pgidx];
}

/* set rmap[page_no(ppa)] -> lpn */
static inline void set_rmap_ent(struct conv_ftl *conv_ftl, uint64_t lpn, struct ppa *ppa)
{
	uint64_t pgidx = ppa2pgidx(conv_ftl, ppa);

	conv_ftl->rmap[pgidx] = lpn;
}

static inline int victim_line_cmp_pri(pqueue_pri_t next, pqueue_pri_t curr)
{
	return (next > curr);
}

static inline pqueue_pri_t victim_line_get_pri(void *a)
{
	return ((struct line *)a)->vpc;
}

static inline void victim_line_set_pri(void *a, pqueue_pri_t pri)
{
	((struct line *)a)->vpc = pri;
}

static inline size_t victim_line_get_pos(void *a)
{
	return ((struct line *)a)->pos;
}

static inline void victim_line_set_pos(void *a, size_t pos)
{
	((struct line *)a)->pos = pos;
}

static inline void consume_write_credit(struct conv_ftl *conv_ftl)
{
	conv_ftl->wfc.write_credits--;
}

static void foreground_gc(struct conv_ftl *conv_ftl);

static inline void check_and_refill_write_credit(struct conv_ftl *conv_ftl)
{
	struct write_flow_control *wfc = &(conv_ftl->wfc);
	if (wfc->write_credits <= 0) {
		foreground_gc(conv_ftl);

		wfc->write_credits += wfc->credits_to_refill;
	}
}

static void init_lines(struct conv_ftl *conv_ftl)
{
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	struct line_mgmt *lm = &conv_ftl->lm;
	struct line *line;
	int i;

	lm->tt_lines = spp->blks_per_pl;
	NVMEV_ASSERT(lm->tt_lines == spp->tt_lines);
	lm->lines = vmalloc(sizeof(struct line) * lm->tt_lines);

	INIT_LIST_HEAD(&lm->free_line_list);
	INIT_LIST_HEAD(&lm->full_line_list);

	lm->victim_line_pq = pqueue_init(spp->tt_lines, victim_line_cmp_pri, victim_line_get_pri,
					 victim_line_set_pri, victim_line_get_pos,
					 victim_line_set_pos);

	lm->free_line_cnt = 0;
	for (i = 0; i < lm->tt_lines; i++) {
		lm->lines[i] = (struct line){
			.id = i,
			.ipc = 0,
			.vpc = 0,
			.last_invalidated_at_ns = 0,
			.pos = 0,
			.entry = LIST_HEAD_INIT(lm->lines[i].entry),
		};

		/* initialize all the lines as free lines */
		list_add_tail(&lm->lines[i].entry, &lm->free_line_list);
		lm->free_line_cnt++;
	}

	NVMEV_ASSERT(lm->free_line_cnt == lm->tt_lines);
	lm->victim_line_cnt = 0;
	lm->full_line_cnt = 0;
}

static void remove_lines(struct conv_ftl *conv_ftl)
{
	pqueue_free(conv_ftl->lm.victim_line_pq);
	vfree(conv_ftl->lm.lines);
}

static void init_write_flow_control(struct conv_ftl *conv_ftl)
{
	struct write_flow_control *wfc = &(conv_ftl->wfc);
	struct ssdparams *spp = &conv_ftl->ssd->sp;

	wfc->write_credits = spp->pgs_per_line;
	wfc->credits_to_refill = spp->pgs_per_line;
}

static inline void check_addr(int a, int max)
{
	NVMEV_ASSERT(a >= 0 && a < max);
}

static struct line *get_next_free_line(struct conv_ftl *conv_ftl)
{
	struct line_mgmt *lm = &conv_ftl->lm;
	struct line *curline = list_first_entry_or_null(&lm->free_line_list, struct line, entry);

	if (!curline) {
		NVMEV_ERROR("No free line left in VIRT !!!!\n");
		return NULL;
	}

	list_del_init(&curline->entry);
	lm->free_line_cnt--;
	NVMEV_DEBUG("%s: free_line_cnt %d\n", __func__, lm->free_line_cnt);
	return curline;
}

static struct write_pointer *__get_wp(struct conv_ftl *ftl, uint32_t io_type)
{
	if (io_type == USER_IO) {
		return &ftl->wp;
	} else if (io_type == GC_IO) {
		return &ftl->gc_wp;
	}

	NVMEV_ASSERT(0);
	return NULL;
}

static void prepare_write_pointer(struct conv_ftl *conv_ftl, uint32_t io_type)
{
	struct write_pointer *wp = __get_wp(conv_ftl, io_type);
	struct line *curline = get_next_free_line(conv_ftl);

	NVMEV_ASSERT(wp);
	NVMEV_ASSERT(curline);

	/* wp->curline is always our next-to-write super-block */
	*wp = (struct write_pointer){
		.curline = curline,
		.ch = 0,
		.lun = 0,
		.pg = 0,
		.blk = curline->id,
		.pl = 0,
	};
}

static void advance_write_pointer(struct conv_ftl *conv_ftl, uint32_t io_type)
{
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	struct line_mgmt *lm = &conv_ftl->lm;
	struct write_pointer *wpp = __get_wp(conv_ftl, io_type);

	NVMEV_DEBUG_VERBOSE("current wpp: ch:%d, lun:%d, pl:%d, blk:%d, pg:%d\n",
			wpp->ch, wpp->lun, wpp->pl, wpp->blk, wpp->pg);

	check_addr(wpp->pg, spp->pgs_per_blk);
	wpp->pg++;
	if ((wpp->pg % spp->pgs_per_oneshotpg) != 0)
		goto out;

	wpp->pg -= spp->pgs_per_oneshotpg;
	check_addr(wpp->ch, spp->nchs);
	wpp->ch++;
	if (wpp->ch != spp->nchs)
		goto out;

	wpp->ch = 0;
	check_addr(wpp->lun, spp->luns_per_ch);
	wpp->lun++;
	/* in this case, we should go to next lun */
	if (wpp->lun != spp->luns_per_ch)
		goto out;

	wpp->lun = 0;
	/* go to next wordline in the block */
	wpp->pg += spp->pgs_per_oneshotpg;
	if (wpp->pg != spp->pgs_per_blk)
		goto out;

	wpp->pg = 0;
	/* move current line to {victim,full} line list */
	if (wpp->curline->vpc == spp->pgs_per_line) {
		/* all pgs are still valid, move to full line list */
		NVMEV_ASSERT(wpp->curline->ipc == 0);
		list_add_tail(&wpp->curline->entry, &lm->full_line_list);
		lm->full_line_cnt++;
		NVMEV_DEBUG_VERBOSE("wpp: move line to full_line_list\n");
	} else {
		NVMEV_DEBUG_VERBOSE("wpp: line is moved to victim list\n");
		NVMEV_ASSERT(wpp->curline->vpc >= 0 && wpp->curline->vpc < spp->pgs_per_line);
		/* there must be some invalid pages in this line */
		NVMEV_ASSERT(wpp->curline->ipc > 0);
		pqueue_insert(lm->victim_line_pq, wpp->curline);
		lm->victim_line_cnt++;
	}
	/* current line is used up, pick another empty line */
	check_addr(wpp->blk, spp->blks_per_pl);
	wpp->curline = get_next_free_line(conv_ftl);
	NVMEV_DEBUG_VERBOSE("wpp: got new clean line %d\n", wpp->curline->id);

	wpp->blk = wpp->curline->id;
	check_addr(wpp->blk, spp->blks_per_pl);

	/* make sure we are starting from page 0 in the super block */
	NVMEV_ASSERT(wpp->pg == 0);
	NVMEV_ASSERT(wpp->lun == 0);
	NVMEV_ASSERT(wpp->ch == 0);
	/* TODO: assume # of pl_per_lun is 1, fix later */
	NVMEV_ASSERT(wpp->pl == 0);
out:
	NVMEV_DEBUG_VERBOSE("advanced wpp: ch:%d, lun:%d, pl:%d, blk:%d, pg:%d (curline %d)\n",
			wpp->ch, wpp->lun, wpp->pl, wpp->blk, wpp->pg, wpp->curline->id);
}

static struct ppa get_new_page(struct conv_ftl *conv_ftl, uint32_t io_type)
{
	struct ppa ppa;
	struct write_pointer *wp = __get_wp(conv_ftl, io_type);

	ppa.ppa = 0;
	ppa.g.ch = wp->ch;
	ppa.g.lun = wp->lun;
	ppa.g.pg = wp->pg;
	ppa.g.blk = wp->blk;
	ppa.g.pl = wp->pl;

	NVMEV_ASSERT(ppa.g.pl == 0);

	return ppa;
}

static void init_maptbl(struct conv_ftl *conv_ftl)
{
	int i;
	struct ssdparams *spp = &conv_ftl->ssd->sp;

	conv_ftl->maptbl = vmalloc(sizeof(struct ppa) * spp->tt_pgs);
	for (i = 0; i < spp->tt_pgs; i++) {
		conv_ftl->maptbl[i].ppa = UNMAPPED_PPA;
	}
}

static void remove_maptbl(struct conv_ftl *conv_ftl)
{
	vfree(conv_ftl->maptbl);
}

static void init_rmap(struct conv_ftl *conv_ftl)
{
	int i;
	struct ssdparams *spp = &conv_ftl->ssd->sp;

	conv_ftl->rmap = vmalloc(sizeof(uint64_t) * spp->tt_pgs);
	for (i = 0; i < spp->tt_pgs; i++) {
		conv_ftl->rmap[i] = INVALID_LPN;
	}
}

static void remove_rmap(struct conv_ftl *conv_ftl)
{
	vfree(conv_ftl->rmap);
}

static void conv_init_ftl(struct conv_ftl *conv_ftl, struct convparams *cpp,
			  struct ssd *ssd, uint32_t ns_id, uint32_t part_id)
{
	/*copy convparams*/
	conv_ftl->cp = *cpp;

	conv_ftl->ssd = ssd;
	conv_ftl->stats = (struct conv_gc_stats){ 0 };
	watgc_v2_init(conv_ftl, ns_id, part_id);

	/* initialize maptbl */
	init_maptbl(conv_ftl); // mapping table

	/* initialize rmap */
	init_rmap(conv_ftl); // reverse mapping table (?)

	/* initialize all the lines */
	init_lines(conv_ftl);

	/* initialize write pointer, this is how we allocate new pages for writes */
	prepare_write_pointer(conv_ftl, USER_IO);
	prepare_write_pointer(conv_ftl, GC_IO);

	init_write_flow_control(conv_ftl);

	NVMEV_INFO("Init FTL instance with %d channels (%ld pages)\n", conv_ftl->ssd->sp.nchs,
		   conv_ftl->ssd->sp.tt_pgs);
	NVMEV_INFO("GC victim policy: %s ns=%u part=%u initial_k=%u "
		   "initial_scale_pct=%u initial_age_ratio=%u warmup_gc=%llu\n",
		   conv_gc_policy_name(), ns_id, part_id, conv_ftl->tuner.param.k,
		   conv_ftl->tuner.param.scale_pct, conv_ftl->tuner.param.age_ratio,
		   WATGC_V2_WARMUP_GC);

	return;
}

static void conv_remove_ftl(struct conv_ftl *conv_ftl)
{
	remove_lines(conv_ftl);
	remove_rmap(conv_ftl);
	remove_maptbl(conv_ftl);
}

static void conv_init_params(struct convparams *cpp)
{
	cpp->op_area_pcent = OP_AREA_PERCENT;
	cpp->gc_thres_lines = 2; /* Need only two lines.(host write, gc)*/
	cpp->gc_thres_lines_high = 2; /* Need only two lines.(host write, gc)*/
	cpp->enable_gc_delay = 1;
	cpp->pba_pcent = (int)((1 + cpp->op_area_pcent) * 100);
}

void conv_init_namespace(struct nvmev_ns *ns, uint32_t id, uint64_t size, void *mapped_addr,
			 uint32_t cpu_nr_dispatcher)
{
	struct ssdparams spp;
	struct convparams cpp;
	struct conv_ftl *conv_ftls;
	struct ssd *ssd;
	uint32_t i;
	const uint32_t nr_parts = SSD_PARTITIONS;

	ssd_init_params(&spp, size, nr_parts);
	conv_init_params(&cpp);

	/* The per-partition 60-arm tables need not be physically contiguous. */
	conv_ftls = vmalloc(sizeof(struct conv_ftl) * nr_parts);
	NVMEV_ASSERT(conv_ftls);

	for (i = 0; i < nr_parts; i++) {
		ssd = kmalloc(sizeof(struct ssd), GFP_KERNEL);
		ssd_init(ssd, &spp, cpu_nr_dispatcher);
		conv_init_ftl(&conv_ftls[i], &cpp, ssd, id, i);
	}

	/* PCIe, Write buffer are shared by all instances*/
	for (i = 1; i < nr_parts; i++) {
		kfree(conv_ftls[i].ssd->pcie->perf_model);
		kfree(conv_ftls[i].ssd->pcie);
		kfree(conv_ftls[i].ssd->write_buffer);

		conv_ftls[i].ssd->pcie = conv_ftls[0].ssd->pcie;
		conv_ftls[i].ssd->write_buffer = conv_ftls[0].ssd->write_buffer;
	}

	ns->id = id;
	ns->csi = NVME_CSI_NVM;
	ns->nr_parts = nr_parts;
	ns->ftls = (void *)conv_ftls;
	ns->size = (uint64_t)((size * 100) / cpp.pba_pcent);
	ns->mapped = mapped_addr;
	/*register io command handler*/
	ns->proc_io_cmd = conv_proc_nvme_io_cmd;

	NVMEV_INFO("FTL physical space: %lld, logical space: %lld (physical/logical * 100 = %d)\n",
		   size, ns->size, cpp.pba_pcent);

	return;
}

void conv_remove_namespace(struct nvmev_ns *ns)
{
	struct conv_ftl *conv_ftls = (struct conv_ftl *)ns->ftls;
	const uint32_t nr_parts = SSD_PARTITIONS;
	uint64_t host_page_writes = 0;
	uint64_t gc_page_writes = 0;
	uint64_t gc_count = 0;
	uint64_t total_page_writes;
	uint64_t waf_integer;
	uint64_t waf_milli;
	uint64_t remainder;
	uint32_t i;

	for (i = 0; i < nr_parts; i++) {
		host_page_writes += conv_ftls[i].stats.host_page_writes;
		gc_page_writes += conv_ftls[i].stats.gc_page_writes;
		gc_count += conv_ftls[i].stats.gc_count;
		watgc_v2_report(&conv_ftls[i]);
	}

	total_page_writes = host_page_writes + gc_page_writes;
	if (host_page_writes) {
		waf_integer = div64_u64_rem(total_page_writes, host_page_writes, &remainder);
		waf_milli = div64_u64(remainder * 1000, host_page_writes);
		NVMEV_INFO("GC stats: ns=%u policy=%s host_pages=%llu gc_pages=%llu "
			   "gc_count=%llu WAF=%llu.%03llu warmup_gc=%llu-per-part\n",
			   ns->id, conv_gc_policy_name(), host_page_writes, gc_page_writes,
			   gc_count, waf_integer, waf_milli, WATGC_V2_WARMUP_GC);
	} else {
		NVMEV_INFO("GC stats: ns=%u policy=%s host_pages=0 gc_pages=%llu "
			   "gc_count=%llu WAF=N/A warmup_gc=%llu-per-part\n",
			   ns->id, conv_gc_policy_name(), gc_page_writes, gc_count,
			   WATGC_V2_WARMUP_GC);
	}

	/* PCIe, Write buffer are shared by all instances*/
	for (i = 1; i < nr_parts; i++) {
		/*
		 * These were freed from conv_init_namespace() already.
		 * Mark these NULL so that ssd_remove() skips it.
		 */
		conv_ftls[i].ssd->pcie = NULL;
		conv_ftls[i].ssd->write_buffer = NULL;
	}

	for (i = 0; i < nr_parts; i++) {
		conv_remove_ftl(&conv_ftls[i]);
		ssd_remove(conv_ftls[i].ssd);
		kfree(conv_ftls[i].ssd);
	}

	vfree(conv_ftls);
	ns->ftls = NULL;
}

static inline bool valid_ppa(struct conv_ftl *conv_ftl, struct ppa *ppa)
{
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	int ch = ppa->g.ch;
	int lun = ppa->g.lun;
	int pl = ppa->g.pl;
	int blk = ppa->g.blk;
	int pg = ppa->g.pg;
	//int sec = ppa->g.sec;

	if (ch < 0 || ch >= spp->nchs)
		return false;
	if (lun < 0 || lun >= spp->luns_per_ch)
		return false;
	if (pl < 0 || pl >= spp->pls_per_lun)
		return false;
	if (blk < 0 || blk >= spp->blks_per_pl)
		return false;
	if (pg < 0 || pg >= spp->pgs_per_blk)
		return false;

	return true;
}

static inline bool valid_lpn(struct conv_ftl *conv_ftl, uint64_t lpn)
{
	return (lpn < conv_ftl->ssd->sp.tt_pgs);
}

static inline bool mapped_ppa(struct ppa *ppa)
{
	return !(ppa->ppa == UNMAPPED_PPA);
}

static inline struct line *get_line(struct conv_ftl *conv_ftl, struct ppa *ppa)
{
	return &(conv_ftl->lm.lines[ppa->g.blk]);
}

/* update SSD status about one page from PG_VALID -> PG_VALID */
static void mark_page_invalid(struct conv_ftl *conv_ftl, struct ppa *ppa)
{
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	struct line_mgmt *lm = &conv_ftl->lm;
	struct nand_block *blk = NULL;
	struct nand_page *pg = NULL;
	bool was_full_line = false;
	struct line *line;

	/* update corresponding page status */
	pg = get_pg(conv_ftl->ssd, ppa);
	NVMEV_ASSERT(pg->status == PG_VALID);
	pg->status = PG_INVALID;

	/* update corresponding block status */
	blk = get_blk(conv_ftl->ssd, ppa);
	NVMEV_ASSERT(blk->ipc >= 0 && blk->ipc < spp->pgs_per_blk);
	blk->ipc++;
	NVMEV_ASSERT(blk->vpc > 0 && blk->vpc <= spp->pgs_per_blk);
	blk->vpc--;

	/* update corresponding line status */
	line = get_line(conv_ftl, ppa);
	/* Age restarts whenever a page in this line is invalidated. */
	line->last_invalidated_at_ns = ktime_get_ns();
	NVMEV_ASSERT(line->ipc >= 0 && line->ipc < spp->pgs_per_line);
	if (line->vpc == spp->pgs_per_line) {
		NVMEV_ASSERT(line->ipc == 0);
		was_full_line = true;
	}
	line->ipc++;
	NVMEV_ASSERT(line->vpc > 0 && line->vpc <= spp->pgs_per_line);
	/* Adjust the position of the victime line in the pq under over-writes */
	if (line->pos) {
		/* Note that line->vpc will be updated by this call */
		pqueue_change_priority(lm->victim_line_pq, line->vpc - 1, line);
	} else {
		line->vpc--;
	}

	if (was_full_line) {
		/* move line: "full" -> "victim" */
		list_del_init(&line->entry);
		lm->full_line_cnt--;
		pqueue_insert(lm->victim_line_pq, line);
		lm->victim_line_cnt++;
	}
}

static void mark_page_valid(struct conv_ftl *conv_ftl, struct ppa *ppa)
{
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	struct nand_block *blk = NULL;
	struct nand_page *pg = NULL;
	struct line *line;

	/* update page status */
	pg = get_pg(conv_ftl->ssd, ppa);
	NVMEV_ASSERT(pg->status == PG_FREE);
	pg->status = PG_VALID;

	/* update corresponding block status */
	blk = get_blk(conv_ftl->ssd, ppa);
	NVMEV_ASSERT(blk->vpc >= 0 && blk->vpc < spp->pgs_per_blk);
	blk->vpc++;

	/* update corresponding line status */
	line = get_line(conv_ftl, ppa);
	NVMEV_ASSERT(line->vpc >= 0 && line->vpc < spp->pgs_per_line);
	line->vpc++;
}

static void mark_block_free(struct conv_ftl *conv_ftl, struct ppa *ppa)
{
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	struct nand_block *blk = get_blk(conv_ftl->ssd, ppa);
	struct nand_page *pg = NULL;
	int i;

	for (i = 0; i < spp->pgs_per_blk; i++) {
		/* reset page status */
		pg = &blk->pg[i];
		NVMEV_ASSERT(pg->nsecs == spp->secs_per_pg);
		pg->status = PG_FREE;
	}

	/* reset block status */
	NVMEV_ASSERT(blk->npgs == spp->pgs_per_blk);
	blk->ipc = 0;
	blk->vpc = 0;
	blk->erase_cnt++;
}

static void gc_read_page(struct conv_ftl *conv_ftl, struct ppa *ppa)
{
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	struct convparams *cpp = &conv_ftl->cp;
	/* advance conv_ftl status, we don't care about how long it takes */
	if (cpp->enable_gc_delay) {
		struct nand_cmd gcr = {
			.type = GC_IO,
			.cmd = NAND_READ,
			.stime = 0,
			.xfer_size = spp->pgsz,
			.interleave_pci_dma = false,
			.ppa = ppa,
		};
		ssd_advance_nand(conv_ftl->ssd, &gcr);
	}
}

/* move valid page data (already in DRAM) from victim line to a new page */
static uint64_t gc_write_page(struct conv_ftl *conv_ftl, struct ppa *old_ppa)
{
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	struct convparams *cpp = &conv_ftl->cp;
	struct ppa new_ppa;
	uint64_t lpn = get_rmap_ent(conv_ftl, old_ppa);

	NVMEV_ASSERT(valid_lpn(conv_ftl, lpn));
	new_ppa = get_new_page(conv_ftl, GC_IO);
	/* update maptbl */
	set_maptbl_ent(conv_ftl, lpn, &new_ppa);
	/* update rmap */
	set_rmap_ent(conv_ftl, lpn, &new_ppa);

	mark_page_valid(conv_ftl, &new_ppa);
	conv_ftl->stats.total_gc_page_writes++;
	if (conv_ftl->stats.measurement_started)
		conv_ftl->stats.gc_page_writes++;

	/* need to advance the write pointer here */
	advance_write_pointer(conv_ftl, GC_IO);

	if (cpp->enable_gc_delay) {
		struct nand_cmd gcw = {
			.type = GC_IO,
			.cmd = NAND_NOP,
			.stime = 0,
			.interleave_pci_dma = false,
			.ppa = &new_ppa,
		};
		if (last_pg_in_wordline(conv_ftl, &new_ppa)) {
			gcw.cmd = NAND_WRITE;
			gcw.xfer_size = spp->pgsz * spp->pgs_per_oneshotpg;
		}

		ssd_advance_nand(conv_ftl->ssd, &gcw);
	}

	/* advance per-ch gc_endtime as well */
#if 0
	new_ch = get_ch(conv_ftl, &new_ppa);
	new_ch->gc_endtime = new_ch->next_ch_avail_time;

	new_lun = get_lun(conv_ftl, &new_ppa);
	new_lun->gc_endtime = new_lun->next_lun_avail_time;
#endif

	return 0;
}

static struct line *select_victim_line(struct conv_ftl *conv_ftl, bool force)
{
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	struct line_mgmt *lm = &conv_ftl->lm;
	struct line *victim_line = NULL;

#if CONV_GC_POLICY == CONV_GC_POLICY_GREEDY
	victim_line = pqueue_peek(lm->victim_line_pq);
	if (!victim_line) {
		return NULL;
	}

	if (!force && (victim_line->vpc > (spp->pgs_per_line / 8))) {
		return NULL;
	}

	pqueue_pop(lm->victim_line_pq);
#else
	struct line *candidate;
	uint64_t now_ns = ktime_get_ns();
	uint32_t i;

	/*
	 * A line's CAT priority changes as wall-clock time advances.  Therefore a
	 * heap key computed at insertion time would become stale.  Scan only the
	 * current victim members (line->pos != 0), then remove the winner from the
	 * existing queue.
	 */
	for (i = 0; i < lm->tt_lines; i++) {
		candidate = &lm->lines[i];
		if (!candidate->pos)
			continue;
		if (!force && candidate->vpc > (spp->pgs_per_line / 8))
			continue;
		if (!victim_line ||
		    cat_fig7_line_is_better(&conv_ftl->tuner.param,
					candidate, victim_line, now_ns))
			victim_line = candidate;
	}

	if (!victim_line)
		return NULL;

	pqueue_remove(lm->victim_line_pq, victim_line);
#endif
	victim_line->pos = 0;
	lm->victim_line_cnt--;

	/* victim_line is a danggling node now */
	return victim_line;
}

/* here ppa identifies the block we want to clean */
static void clean_one_block(struct conv_ftl *conv_ftl, struct ppa *ppa)
{
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	struct nand_page *pg_iter = NULL;
	int cnt = 0;
	int pg;

	for (pg = 0; pg < spp->pgs_per_blk; pg++) {
		ppa->g.pg = pg;
		pg_iter = get_pg(conv_ftl->ssd, ppa);
		/* there shouldn't be any free page in victim blocks */
		NVMEV_ASSERT(pg_iter->status != PG_FREE);
		if (pg_iter->status == PG_VALID) {
			gc_read_page(conv_ftl, ppa);
			/* delay the maptbl update until "write" happens */
			gc_write_page(conv_ftl, ppa);
			cnt++;
		}
	}

	NVMEV_ASSERT(get_blk(conv_ftl->ssd, ppa)->vpc == cnt);
}

/* here ppa identifies the block we want to clean */
static void clean_one_flashpg(struct conv_ftl *conv_ftl, struct ppa *ppa)
{
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	struct convparams *cpp = &conv_ftl->cp;
	struct nand_page *pg_iter = NULL;
	int cnt = 0, i = 0;
	uint64_t completed_time = 0;
	struct ppa ppa_copy = *ppa;

	for (i = 0; i < spp->pgs_per_flashpg; i++) {
		pg_iter = get_pg(conv_ftl->ssd, &ppa_copy);
		/* there shouldn't be any free page in victim blocks */
		NVMEV_ASSERT(pg_iter->status != PG_FREE);
		if (pg_iter->status == PG_VALID)
			cnt++;

		ppa_copy.g.pg++;
	}

	ppa_copy = *ppa;

	if (cnt <= 0)
		return;

	if (cpp->enable_gc_delay) {
		struct nand_cmd gcr = {
			.type = GC_IO,
			.cmd = NAND_READ,
			.stime = 0,
			.xfer_size = spp->pgsz * cnt,
			.interleave_pci_dma = false,
			.ppa = &ppa_copy,
		};
		completed_time = ssd_advance_nand(conv_ftl->ssd, &gcr);
	}

	for (i = 0; i < spp->pgs_per_flashpg; i++) {
		pg_iter = get_pg(conv_ftl->ssd, &ppa_copy);

		/* there shouldn't be any free page in victim blocks */
		if (pg_iter->status == PG_VALID) {
			/* delay the maptbl update until "write" happens */
			gc_write_page(conv_ftl, &ppa_copy);
		}

		ppa_copy.g.pg++;
	}
}

static void mark_line_free(struct conv_ftl *conv_ftl, struct ppa *ppa)
{
	struct line_mgmt *lm = &conv_ftl->lm;
	struct line *line = get_line(conv_ftl, ppa);
	line->ipc = 0;
	line->vpc = 0;
	line->last_invalidated_at_ns = 0;
	/* move this line to free line list */
	list_add_tail(&line->entry, &lm->free_line_list);
	lm->free_line_cnt++;
}

static int do_gc(struct conv_ftl *conv_ftl, bool force)
{
	struct line *victim_line = NULL;
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	struct ppa ppa;
	int flashpg;

	victim_line = select_victim_line(conv_ftl, force);
	if (!victim_line) {
		return -1;
	}

	ppa.g.blk = victim_line->id;
	NVMEV_DEBUG_VERBOSE("GC-ing line:%d,ipc=%d(%d),victim=%d,full=%d,free=%d\n", ppa.g.blk,
		    victim_line->ipc, victim_line->vpc, conv_ftl->lm.victim_line_cnt,
		    conv_ftl->lm.full_line_cnt, conv_ftl->lm.free_line_cnt);

	conv_ftl->wfc.credits_to_refill = victim_line->ipc;

	/* copy back valid data */
	for (flashpg = 0; flashpg < spp->flashpgs_per_blk; flashpg++) {
		int ch, lun;

		ppa.g.pg = flashpg * spp->pgs_per_flashpg;
		for (ch = 0; ch < spp->nchs; ch++) {
			for (lun = 0; lun < spp->luns_per_ch; lun++) {
				struct nand_lun *lunp;

				ppa.g.ch = ch;
				ppa.g.lun = lun;
				ppa.g.pl = 0;
				lunp = get_lun(conv_ftl->ssd, &ppa);
				clean_one_flashpg(conv_ftl, &ppa);

				if (flashpg == (spp->flashpgs_per_blk - 1)) {
					struct convparams *cpp = &conv_ftl->cp;

					mark_block_free(conv_ftl, &ppa);

					if (cpp->enable_gc_delay) {
						struct nand_cmd gce = {
							.type = GC_IO,
							.cmd = NAND_ERASE,
							.stime = 0,
							.interleave_pci_dma = false,
							.ppa = &ppa,
						};
						ssd_advance_nand(conv_ftl->ssd, &gce);
					}

					lunp->gc_endtime = lunp->next_lun_avail_time;
				}
			}
		}
	}

	/* update line status */
	mark_line_free(conv_ftl, &ppa);
	conv_ftl->stats.total_gc_count++;
	if (conv_ftl->stats.measurement_started) {
		conv_ftl->stats.gc_count++;
	} else if (conv_ftl->stats.total_gc_count >= WATGC_V2_WARMUP_GC) {
		/* Start AFTER the whole boundary GC, including all its page copies. */
		conv_ftl->stats.measurement_started = true;
	}
	/* The arm that performed this entire GC remains installed until here. */
	watgc_v2_on_gc(conv_ftl, ktime_get_ns());

	return 0;
}

static void foreground_gc(struct conv_ftl *conv_ftl)
{
	if (should_gc_high(conv_ftl)) {
		NVMEV_DEBUG_VERBOSE("should_gc_high passed");
		/* perform GC here until !should_gc(conv_ftl) */
		do_gc(conv_ftl, true);
	}
}

static bool is_same_flash_page(struct conv_ftl *conv_ftl, struct ppa ppa1, struct ppa ppa2)
{
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	uint32_t ppa1_page = ppa1.g.pg / spp->pgs_per_flashpg;
	uint32_t ppa2_page = ppa2.g.pg / spp->pgs_per_flashpg;

	return (ppa1.h.blk_in_ssd == ppa2.h.blk_in_ssd) && (ppa1_page == ppa2_page);
}

static bool conv_read(struct nvmev_ns *ns, struct nvmev_request *req, struct nvmev_result *ret)
{
	struct conv_ftl *conv_ftls = (struct conv_ftl *)ns->ftls;
	struct conv_ftl *conv_ftl = &conv_ftls[0];
	/* spp are shared by all instances*/
	struct ssdparams *spp = &conv_ftl->ssd->sp;

	struct nvme_command *cmd = req->cmd;
	uint64_t lba = cmd->rw.slba;
	uint64_t nr_lba = (cmd->rw.length + 1);
	uint64_t start_lpn = lba / spp->secs_per_pg;
	uint64_t end_lpn = (lba + nr_lba - 1) / spp->secs_per_pg;
	uint64_t lpn;
	uint64_t nsecs_start = req->nsecs_start;
	uint64_t nsecs_completed, nsecs_latest = nsecs_start;
	uint32_t xfer_size, i;
	uint32_t nr_parts = ns->nr_parts;

	struct ppa prev_ppa;
	struct nand_cmd srd = {
		.type = USER_IO,
		.cmd = NAND_READ,
		.stime = nsecs_start,
		.interleave_pci_dma = true,
	};

	NVMEV_ASSERT(conv_ftls);
	NVMEV_DEBUG_VERBOSE("%s: start_lpn=%lld, len=%lld, end_lpn=%lld", __func__, start_lpn, nr_lba, end_lpn);
	if ((end_lpn / nr_parts) >= spp->tt_pgs) {
		NVMEV_ERROR("%s: lpn passed FTL range (start_lpn=%lld > tt_pgs=%ld)\n", __func__,
			    start_lpn, spp->tt_pgs);
		return false;
	}

	if (LBA_TO_BYTE(nr_lba) <= (KB(4) * nr_parts)) {
		srd.stime += spp->fw_4kb_rd_lat;
	} else {
		srd.stime += spp->fw_rd_lat;
	}

	for (i = 0; (i < nr_parts) && (start_lpn <= end_lpn); i++, start_lpn++) {
		conv_ftl = &conv_ftls[start_lpn % nr_parts];
		xfer_size = 0;
		prev_ppa = get_maptbl_ent(conv_ftl, start_lpn / nr_parts);

		/* normal IO read path */
		for (lpn = start_lpn; lpn <= end_lpn; lpn += nr_parts) {
			uint64_t local_lpn;
			struct ppa cur_ppa;

			local_lpn = lpn / nr_parts;
			cur_ppa = get_maptbl_ent(conv_ftl, local_lpn);
			if (!mapped_ppa(&cur_ppa) || !valid_ppa(conv_ftl, &cur_ppa)) {
				NVMEV_DEBUG_VERBOSE("lpn 0x%llx not mapped to valid ppa\n", local_lpn);
				NVMEV_DEBUG_VERBOSE("Invalid ppa,ch:%d,lun:%d,blk:%d,pl:%d,pg:%d\n",
					    cur_ppa.g.ch, cur_ppa.g.lun, cur_ppa.g.blk,
					    cur_ppa.g.pl, cur_ppa.g.pg);
				continue;
			}

			// aggregate read io in same flash page
			if (mapped_ppa(&prev_ppa) &&
			    is_same_flash_page(conv_ftl, cur_ppa, prev_ppa)) {
				xfer_size += spp->pgsz;
				continue;
			}

			if (xfer_size > 0) {
				srd.xfer_size = xfer_size;
				srd.ppa = &prev_ppa;
				nsecs_completed = ssd_advance_nand(conv_ftl->ssd, &srd);
				nsecs_latest = max(nsecs_completed, nsecs_latest);
			}

			xfer_size = spp->pgsz;
			prev_ppa = cur_ppa;
		}

		// issue remaining io
		if (xfer_size > 0) {
			srd.xfer_size = xfer_size;
			srd.ppa = &prev_ppa;
			nsecs_completed = ssd_advance_nand(conv_ftl->ssd, &srd);
			nsecs_latest = max(nsecs_completed, nsecs_latest);
		}
	}

	ret->nsecs_target = nsecs_latest;
	ret->status = NVME_SC_SUCCESS;
	return true;
}

static bool conv_write(struct nvmev_ns *ns, struct nvmev_request *req, struct nvmev_result *ret)
{
	struct conv_ftl *conv_ftls = (struct conv_ftl *)ns->ftls;
	struct conv_ftl *conv_ftl = &conv_ftls[0];

	/* wbuf and spp are shared by all instances */
	struct ssdparams *spp = &conv_ftl->ssd->sp;
	struct buffer *wbuf = conv_ftl->ssd->write_buffer;

	struct nvme_command *cmd = req->cmd;
	uint64_t lba = cmd->rw.slba;
	uint64_t nr_lba = (cmd->rw.length + 1);
	uint64_t start_lpn = lba / spp->secs_per_pg;
	uint64_t end_lpn = (lba + nr_lba - 1) / spp->secs_per_pg;

	uint64_t lpn;
	uint32_t nr_parts = ns->nr_parts;

	uint64_t nsecs_latest;
	uint64_t nsecs_xfer_completed;
	uint32_t allocated_buf_size;

	struct nand_cmd swr = {
		.type = USER_IO,
		.cmd = NAND_WRITE,
		.interleave_pci_dma = false,
		.xfer_size = spp->pgsz * spp->pgs_per_oneshotpg,
	};

	NVMEV_DEBUG_VERBOSE("%s: start_lpn=%lld, len=%lld, end_lpn=%lld", __func__, start_lpn, nr_lba, end_lpn);
	if ((end_lpn / nr_parts) >= spp->tt_pgs) {
		NVMEV_ERROR("%s: lpn passed FTL range (start_lpn=%lld > tt_pgs=%ld)\n",
				__func__, start_lpn, spp->tt_pgs);
		return false;
	}

	allocated_buf_size = buffer_allocate(wbuf, LBA_TO_BYTE(nr_lba));
	if (allocated_buf_size < LBA_TO_BYTE(nr_lba))
		return false;

	nsecs_latest =
		ssd_advance_write_buffer(conv_ftl->ssd, req->nsecs_start, LBA_TO_BYTE(nr_lba));
	nsecs_xfer_completed = nsecs_latest;

	swr.stime = nsecs_latest;

	for (lpn = start_lpn; lpn <= end_lpn; lpn++) {
		uint64_t local_lpn;
		uint64_t nsecs_completed = 0;
		struct ppa ppa;

		conv_ftl = &conv_ftls[lpn % nr_parts];
		local_lpn = lpn / nr_parts;
		ppa = get_maptbl_ent(
			conv_ftl, local_lpn); // Check whether the given LPN has been written before
		if (mapped_ppa(&ppa)) {
			/* update old page information first */
			mark_page_invalid(conv_ftl, &ppa);
			set_rmap_ent(conv_ftl, INVALID_LPN, &ppa);
			NVMEV_DEBUG("%s: %lld is invalid, ", __func__, ppa2pgidx(conv_ftl, &ppa));
		}

		/* new write */
		ppa = get_new_page(conv_ftl, USER_IO);
		/* update maptbl */
		set_maptbl_ent(conv_ftl, local_lpn, &ppa);
		NVMEV_DEBUG("%s: got new ppa %lld, ", __func__, ppa2pgidx(conv_ftl, &ppa));
		/* update rmap */
		set_rmap_ent(conv_ftl, local_lpn, &ppa);

		mark_page_valid(conv_ftl, &ppa);
		conv_ftl->stats.total_host_page_writes++;
		if (conv_ftl->stats.measurement_started)
			conv_ftl->stats.host_page_writes++;

		/* need to advance the write pointer here */
		advance_write_pointer(conv_ftl, USER_IO);

		/* Aggregate write io in flash page */
		if (last_pg_in_wordline(conv_ftl, &ppa)) {
			swr.ppa = &ppa;

			nsecs_completed = ssd_advance_nand(conv_ftl->ssd, &swr);
			nsecs_latest = max(nsecs_completed, nsecs_latest);

			schedule_internal_operation(req->sq_id, nsecs_completed, wbuf,
						    spp->pgs_per_oneshotpg * spp->pgsz);
		}

		consume_write_credit(conv_ftl);
		check_and_refill_write_credit(conv_ftl);
	}

	if ((cmd->rw.control & NVME_RW_FUA) || (spp->write_early_completion == 0)) {
		/* Wait all flash operations */
		ret->nsecs_target = nsecs_latest;
	} else {
		/* Early completion */
		ret->nsecs_target = nsecs_xfer_completed;
	}
	ret->status = NVME_SC_SUCCESS;

	return true;
}

static void conv_flush(struct nvmev_ns *ns, struct nvmev_request *req, struct nvmev_result *ret)
{
	uint64_t start, latest;
	uint32_t i;
	struct conv_ftl *conv_ftls = (struct conv_ftl *)ns->ftls;

	start = local_clock();
	latest = start;
	for (i = 0; i < ns->nr_parts; i++) {
		latest = max(latest, ssd_next_idle_time(conv_ftls[i].ssd));
	}

	NVMEV_DEBUG_VERBOSE("%s: latency=%llu\n", __func__, latest - start);

	ret->status = NVME_SC_SUCCESS;
	ret->nsecs_target = latest;
	return;
}

bool conv_proc_nvme_io_cmd(struct nvmev_ns *ns, struct nvmev_request *req, struct nvmev_result *ret)
{
	struct nvme_command *cmd = req->cmd;

	NVMEV_ASSERT(ns->csi == NVME_CSI_NVM);

	switch (cmd->common.opcode) {
	case nvme_cmd_write:
		if (!conv_write(ns, req, ret))
			return false;
		break;
	case nvme_cmd_read:
		if (!conv_read(ns, req, ret))
			return false;
		break;
	case nvme_cmd_flush:
		conv_flush(ns, req, ret);
		break;
	default:
		NVMEV_ERROR("%s: command not implemented: %s (0x%x)\n", __func__,
				nvme_opcode_string(cmd->common.opcode), cmd->common.opcode);
		break;
	}

	return true;
}
