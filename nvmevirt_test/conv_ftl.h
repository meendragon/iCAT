// SPDX-License-Identifier: GPL-2.0-only
#ifndef _NVMEVIRT_CONV_FTL_H
#define _NVMEVIRT_CONV_FTL_H

#include <linux/types.h>
#include "pqueue/pqueue.h"
#include "ssd_config.h"
#include "ssd.h"

/* Online learning is the default.  0/1 are optional comparison baselines. */
#define CONV_GC_POLICY_GREEDY 0
#define CONV_GC_POLICY_CAT_FIG7 1 /* fixed reference: K=7, scale=100, ratio=7 */
#define CONV_GC_POLICY_WATGC_V2 2
#ifndef CONV_GC_POLICY
#define CONV_GC_POLICY CONV_GC_POLICY_WATGC_V2
#endif
#if CONV_GC_POLICY != CONV_GC_POLICY_GREEDY && \
	CONV_GC_POLICY != CONV_GC_POLICY_CAT_FIG7 && \
	CONV_GC_POLICY != CONV_GC_POLICY_WATGC_V2
#error "Invalid CONV_GC_POLICY (0=greedy, 1=fixed CAT, 2=online v2)"
#endif
#if defined(CAT_FIG7_K) || defined(CAT_FIG7_SCALE_PCT) || defined(CAT_FIG7_AGE_RATIO)
#error "Remove old CAT_FIG7_* sweep flags: v2 searches their complete grid online"
#endif

/* ((k_index * SCALE_N) + scale_index) * RATIO_N + ratio_index. */
#define WATGC_V2_K_N 4U
#define WATGC_V2_SCALE_N 5U
#define WATGC_V2_RATIO_N 3U
#define WATGC_V2_ARM_N (WATGC_V2_K_N * WATGC_V2_SCALE_N * WATGC_V2_RATIO_N)
#define WATGC_V2_INITIAL_ARM 37U /* (7, 100, 7); no reward prior */
#define WATGC_V2_Q 16U
#define WATGC_V2_ONE (1ULL << WATGC_V2_Q)

/* All thresholds are PER FTL PARTITION.  Count only completed GC cycles. */
#define WATGC_V2_WARMUP_GC 100ULL
#define WATGC_V2_BURNIN_GC 32ULL
#define WATGC_V2_BURNIN_HOST_PAGES 32768ULL
#define WATGC_V2_WINDOW_GC 64ULL
#define WATGC_V2_WINDOW_HOST_PAGES 65536ULL /* 256 MiB for 4 KiB pages */
/* No timeout may turn an empty or undersized interval into a reward. */
#define WATGC_V2_MAX_WINDOW_GC 4096ULL
#define WATGC_V2_MAX_WINDOW_NS (300ULL * 1000000000ULL)

/* Forgetting per VALID observation; newest observation is not discounted. */
#define WATGC_V2_GAMMA_Q16 65503ULL /* 0.99949646, half-life about 1376 windows */
#define WATGC_V2_UCB_C_Q16 16384ULL /* 0.25 WAF units; heuristic exploration */
#define WATGC_V2_MIN_VISITS 3U
#define WATGC_V2_STABLE_WINDOWS 12U
#define WATGC_V2_BEST_CONFIRMATIONS 3U
#define WATGC_V2_TOLERANCE_Q16 328ULL /* about 0.5%, relative incumbent hysteresis */
#define WATGC_V2_PROBE_EVERY 8U
#define WATGC_V2_STALE_WINDOWS 240ULL
#define WATGC_V2_DRIFT_Q16 8192ULL /* 12.5% relative change */
#define WATGC_V2_DRIFT_WINDOWS 3U

struct convparams {
	uint32_t gc_thres_lines;
	uint32_t gc_thres_lines_high;
	bool enable_gc_delay;
	double op_area_pcent;
	int pba_pcent;
};

struct line {
	int id;
	int ipc;
	int vpc;
	/* Age resets on every invalidation, using the same monotonic clock as GC. */
	uint64_t last_invalidated_at_ns;
	struct list_head entry;
	size_t pos;
};

struct write_pointer {
	struct line *curline;
	uint32_t ch;
	uint32_t lun;
	uint32_t pg;
	uint32_t blk;
	uint32_t pl;
};

struct line_mgmt {
	struct line *lines;
	struct list_head free_line_list;
	pqueue_t *victim_line_pq;
	struct list_head full_line_list;
	uint32_t tt_lines;
	uint32_t free_line_cnt;
	uint32_t victim_line_cnt;
	uint32_t full_line_cnt;
};

struct write_flow_control {
	uint32_t write_credits;
	uint32_t credits_to_refill;
};

struct conv_gc_stats {
	/* Measured device totals: include exploration and all post-warmup writes. */
	uint64_t host_page_writes;
	uint64_t gc_page_writes;
	uint64_t gc_count;
	bool measurement_started;
	/* Lifetime counters are never reset by the learner or a workload change. */
	uint64_t total_host_page_writes;
	uint64_t total_gc_page_writes;
	uint64_t total_gc_count;
};

struct watgc_v2_param {
	uint32_t k;
	uint32_t scale_pct;
	uint32_t age_ratio;
	uint64_t threshold_ns[9];
	uint32_t age_value[10];
};

struct watgc_v2_arm {
	/* Paired Q16 PAGE sums: WAF = 1 + gc_pages / host_pages.  Fractions
	 * prevent low-copy arms from becoming fake WAF=1 through rounding. */
	uint64_t host_pages;
	uint64_t gc_pages;
	uint64_t count_q16;
	uint64_t visits;
	uint64_t last_window;
};

enum watgc_v2_phase {
	WATGC_V2_WARMUP,
	WATGC_V2_BURNIN,
	WATGC_V2_MEASURE,
};

struct watgc_v2_tuner {
	struct watgc_v2_arm arm[WATGC_V2_ARM_N];
	struct watgc_v2_param param; /* cached only when current arm changes */
	enum watgc_v2_phase phase;
	uint32_t current_arm;
	uint32_t best_arm;
	uint32_t ns_id;
	uint32_t part_id;
	uint64_t epoch;
	uint64_t windows; /* accepted observations, across epochs */
	uint64_t epoch_windows;
	uint64_t discarded_windows;
	uint64_t phase_host_start;
	uint64_t phase_gcpage_start;
	uint64_t phase_gc_start;
	uint64_t phase_start_ns;
	uint32_t stable_windows;
	uint32_t best_confirmations;
	uint32_t exploit_windows;
	uint32_t drift_windows;
	uint32_t reference_waf_q16;
	bool settled; /* empirical stability, NOT a proof of a global optimum */
};

struct conv_ftl {
	struct ssd *ssd;
	struct convparams cp;
	struct ppa *maptbl;
	uint64_t *rmap;
	struct write_pointer wp;
	struct write_pointer gc_wp;
	struct line_mgmt lm;
	struct write_flow_control wfc;
	struct conv_gc_stats stats;
	/* Each FTL instance is owned by its existing serialized I/O dispatcher. */
	struct watgc_v2_tuner tuner;
};

void conv_init_namespace(struct nvmev_ns *ns, uint32_t id, uint64_t size,
			 void *mapped_addr, uint32_t cpu_nr_dispatcher);
void conv_remove_namespace(struct nvmev_ns *ns);
bool conv_proc_nvme_io_cmd(struct nvmev_ns *ns, struct nvmev_request *req,
			   struct nvmev_result *ret);

#endif
