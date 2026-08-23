# CAT Fig. 7 온라인 튜닝 사전·최종 실험 계획서

## 0. Age정의를 Cost-Benefit으로 맞출지 혹은 CAT 기준으로 맞출지

## 1. 연구 목적

본 실험의 목적은 CAT의 전체 기법을 재현하는 것이 아니라, Fig. 7의 `raw age → AgeLevel` 변환이 workload에 따라 튜닝되어야 함을 보이고 이를 온라인 Q-learning의 action 설계 근거로 사용하는 것이다.

검증할 연구 질문은 다음과 같다.

1. 경계값, 출력값 강도, 구간 개수는 각각 WAF에 유의미한 영향을 주는가?
2. 최적 age 변환 설정은 workload와 overwrite 시간축에 따라 달라지는가?
3. 온라인 모델은 고정된 Fig. 7과 Greedy보다 낮은 WAF를 달성하는가?
4. 모델이 선택한 설정이 실제 victim의 age, vpc, ipc 변화로 설명되는가?

## 2. 실험 범위와 고정 조건

### 2.1 정책 범위

- GC victim 단위는 NVMeVirt의 `line`으로 고정한다.
- Raw age는 `GC 선택 시각 - line의 첫 페이지 기록 시각`으로 고정한다.
- 페이지 invalidation은 line age를 초기화하지 않는다.
- Line age는 erase 후 free line으로 반환될 때만 0으로 초기화한다.
- Age 변환 함수는 계단형을 유지한다.
- Erase count와 wear-leveling 항은 victim 점수에서 제외한다.
- Hot/cold fine-grained redistribution은 적용하지 않는다.
- Host write와 GC relocation은 기존 `wp`, `gc_wp` 경로를 그대로 사용한다.
- GC 시작 조건, OP, line 크기 및 NAND 지연 모델은 모든 정책에서 동일하게 유지한다.

따라서 본 연구의 정책 명칭은 `CAT Fig.7 cost-age victim selection without hot/cold redistribution`으로 사용한다.

### 2.2 기본 점수

CAT-Fig.7 후보 line의 점수는 다음과 같으며 낮을수록 우선 선택한다.

\[
Score(line)=\frac{vpc}{ipc\times AgeLevel}
\]

Greedy는 age를 사용하지 않고 vpc가 가장 작은 line을 선택한다.

### 2.3 하드웨어 및 실행 조건

- NVMeVirt 물리 용량: 약 8 GiB
- 논리 namespace: 약 7.6 GiB
- 파일시스템: ext4
- 온라인 discard 및 실험 중 `fstrim`: 사용하지 않음
- 각 run마다 모듈 재로드, ext4 재포맷, workload별 preconditioning 수행
- 측정 시간: 기본 600초 이상으로 설정하여 원본의 360초 AgeLevel까지 관측
- `α=4`의 마지막 경계는 1,440초이므로 경계 스케일 확인 run은 모든 α에 동일하게 1,800초를 적용
- 종료 순서: workload 종료 → NVMe flush → 모듈 제거 → run marker 사이 dmesg 저장
- 동일 비교군에서는 seed, 데이터 크기, 요청량 및 실행 시간을 동일하게 유지

## 3. 평가 워크로드

| Workload | 역할 | 기본 구성 | Overwrite 시간축 변경 방법 |
|---|---|---|---|
| fio | 통제된 synthetic 기준 | 1 GiB hot + 5 GiB cold, 4 KiB random write, 600초 | 영역 크기와 `rate_iops` 조절 |
| SQLite | WAL 기반 transaction workload | 2.5~3 GiB DB, WAL mode, update-heavy transaction | hot table/key 범위와 transaction rate 조절 |
| RocksDB | LSM compaction workload | 2.5~3 GiB DB, compression/compaction 설정 고정 | key range와 overwrite operation rate 조절 |
| Filebench | 파일시스템 macro workload | `fileserver` profile, 약 3 GiB fileset | fileset 크기와 worker 수 조절 |

### 3.1 Workload별 preconditioning

- fio: 6 GiB `preset.fio` 순차 쓰기 후 동일 파일에 test workload를 수행한다.
- SQLite/RocksDB/Filebench: sequential filler로 FTL을 먼저 채운 후 filler를 삭제하되 TRIM은 수행하지 않고, 각 workload의 데이터셋을 생성한다.
- RocksDB는 compaction 임시 공간이 필요하므로 실제 DB 크기를 2.5~3 GiB로 제한한다.
- 데이터셋 생성과 compaction 안정화가 끝난 후 통계 counter를 초기화하고 측정 구간을 시작한다.
- Counter 초기화는 FTL mapping과 line 상태를 유지하고 통계값만 0으로 만드는 별도 reset hook을 사용한다.

## 4. 공통 측정 지표

### 4.1 주 지표

\[
FTL\ WAF=\frac{HostPageWrites+GCPageWrites}{HostPageWrites}
\]

### 4.2 보조 지표

- `GCPageWrites`
- `GCCount`
- GC당 평균 복사 page: `GCPageWrites / GCCount`
- 선택 victim의 평균 vpc, ipc, raw age, AgeLevel
- Workload throughput: fio IOPS, SQLite TPS, RocksDB ops/s, Filebench ops/s
- p50/p99 latency
- CAT scan 기반 selection 시간 또는 CPU overhead

RocksDB에서는 FTL WAF와 별도로 다음 end-to-end 지표를 선택적으로 기록한다.

\[
EndToEnd\ WA=\frac{NAND\ writes}{Application\ user\ writes}
\]

## 5. 단계별 실험

## 실험 1. 경계값 전체 스케일 ablation

### 목적

Fig. 7 경계값의 절대 시간축이 WAF에 영향을 주는지 확인하고 Q-table의 boundary-scale action 후보를 선정한다.

### 독립변수

- 원본 경계: `{10, 20, 45, 90, 180, 360}`초
- 배율: `α = {0.25, 0.5, 1, 2, 4}`
- 적용 경계: `b'_k = α × b_k`
- `K=7`, 출력값 `{1,2,3,4,5,6,7}`은 고정한다.

### 실행

- 네 workload의 기본 구성에서 5개 α를 각각 실행한다.
- 600초 pilot으로 명백히 불필요한 설정을 먼저 확인한다.
- 경계 스케일 최종 비교는 모든 α를 동일한 1,800초 동안 실행한다.
- 각 조합은 pilot 및 확인 단계에서 3회 반복한다.
- Greedy는 age를 사용하지 않는 참조선으로 함께 표시한다.

### 판정

- α에 따른 WAF 곡선이 평탄하지 않으면 경계값을 action 축으로 채택한다.
- Workload별 최적 α가 다르면 workload-dependent tuning의 1차 증거로 사용한다.
- 차이가 없는 α는 이후 Q-table action에서 제거한다.

## 실험 2. 출력값 강도 ablation

### 목적

AgeLevel이 victim 점수에 미치는 최대 영향력의 필요 범위를 정한다.

### 독립변수

- 경계값은 원본 Fig. 7로 고정한다.
- Weak: `{1,1,2,2,3,3,4}`, 최대 비율 `R=4`
- Original: `{1,2,3,4,5,6,7}`, 최대 비율 `R=7`
- Strong: `{1,2,4,6,8,12,16}`, 최대 비율 `R=16`

### 실행 및 판정

- 네 workload에서 각 강도를 3회 반복한다.
- 강도별 WAF와 victim 평균 vpc를 비교한다.
- Strong에서 vpc와 GC copy가 증가하면 age 과대강조의 증거로 사용한다.
- 유효한 강도만 Q-table의 output-strength action으로 유지한다.

## 실험 3. 구간 개수 K ablation

### 목적

Age 구분 해상도와 Q-table action 복잡도 사이의 적절한 K 범위를 정한다.

### 독립변수

- `K = {2,4,7,10}`
- 마지막 경계는 항상 360초로 유지한다.
- K가 달라도 최대 age 영향력은 `R=7`로 정규화한다.
- K=7은 원본 경계와 출력값을 사용한다.
- K<7은 원본 구간을 병합하고, K>7은 넓은 원본 구간을 분할한다.

예시 설정은 다음과 같다.

| K | 경계값(초) | 출력 비율 |
|---:|---|---|
| 2 | `{360}` | `{1,7}` |
| 4 | `{20,90,360}` | `{1,3,5,7}` |
| 7 | `{10,20,45,90,180,360}` | `{1,2,3,4,5,6,7}` |
| 10 | `{10,20,45,68,90,135,180,270,360}` | 1에서 7까지 균등 증가 |

### 실행 및 판정

- 네 workload에서 각 K를 3회 반복한다.
- WAF, GC copy 및 victim AgeLevel histogram을 비교한다.
- 성능 차이가 거의 없는 인접 K는 더 작은 K로 통합한다.
- 선택된 K 후보만 최종 Q-table action 조합에 포함한다.

## 실험 4. Overwrite 시간축별 최적 설정 비교

### 목적

동일한 workload에서도 overwrite 주기가 바뀌면 최적 Fig. 7 설정이 이동한다는 사실을 보여 온라인 튜닝의 필요성을 확립한다.

### 구성

- 각 workload에 Short, Medium, Long overwrite-period 변형을 만든다.
- 목표 대표 구간은 `<20초`, `45~90초`, `>180초`로 한다.
- 실제 LBA overwrite 간격은 workload 설정값만으로 가정하지 않고 FTL에서 표본 측정한다.
- 실험 1~3에서 남은 α, 강도, K 후보만 사용한다.

### 실행 및 판정

- 각 workload-period-policy 조합을 3회 반복한다.
- Overwrite 시간이 길어질수록 최적 α 또는 age 강도가 이동하는지 확인한다.
- 동일 고정 설정이 모든 period에서 최적이 아니면 online adaptation의 핵심 동기로 사용한다.
- 이 결과를 Q-learning state 구간과 action 범위 설계에 사용한다.

## 실험 5. Victim 선택 원인 및 모델 설명

### 목적

온라인 모델이 왜 특정 설정을 선택했고 그 설정이 실제 victim을 어떻게 바꾸었는지 설명한다.

### 수집 정보

- 선택 시점의 raw age와 AgeLevel
- victim의 vpc, ipc 및 CAT score
- 선택된 α, 출력 강도, K
- GC당 복사 page 수
- State/action/reward 전이

### 수집 방식

- 매 GC마다 `printk`하지 않고 메모리 histogram과 누적 counter를 사용한다.
- 상세 victim record는 1/N sampling하거나 ring buffer에 제한적으로 저장한다.
- 실험 종료 시 dmesg 또는 debugfs/sysfs를 통해 한 번에 dump한다.

### 분석

- `CAT Original`, `Offline-best`, `RL-tuned`가 선택한 victim을 비교한다.
- 모델이 작은 α를 선택했을 때 낮은 age 구간의 victim 비율이 증가하는지 확인한다.
- 강한 출력값을 선택했을 때 더 오래됐지만 vpc가 많은 line을 선택하는지 확인한다.
- WAF 개선 또는 악화를 victim copy 변화와 연결해 설명한다.

## 실험 6. 최종 전체 WAF 비교

### 목적

온라인 튜닝 모델이 네 workload와 미학습 workload 변형에서 기존 정책보다 일관되게 낮은 WAF를 달성하는지 평가한다.

### 비교 정책

1. Greedy
2. CAT Fig. 7 Original
3. Static-global-best: 학습 workload 전체에서 하나로 고른 고정 설정
4. Per-workload offline oracle: workload별 사후 최적값이며 달성 가능한 상한선으로만 사용
5. RL-tuned CAT: 실행 중 설정을 변경하는 최종 모델

### 실행

- 네 workload의 기본 구성과 미학습 seed/period 변형을 평가한다.
- 최종 평가는 조합당 최소 5회 반복한다.
- 정책 실행 순서는 무작위화하여 시간 순서에 따른 시스템 영향을 줄인다.
- RL 학습에 사용한 run과 최종 평가 run을 분리한다.

### 최종 결과

- Workload별 FTL WAF와 95% 신뢰구간
- Greedy 대비 WAF 감소율
- CAT Original 대비 WAF 감소율
- Offline oracle과 RL 사이의 성능 차이
- GC copy, throughput 및 p99 latency trade-off
- Workload 전환 전후 action 변화와 수렴 시간

## 6. 실험 규모

| 단계 | 조합 수(반복 제외) | 반복 | 목적 |
|---|---:|---:|---|
| 실험 1 | 4 workloads × 5 α = 20 | 3 | 경계 action 선정 |
| 실험 2 | 4 workloads × 3 strengths = 12 | 3 | 출력 action 선정 |
| 실험 3 | 4 workloads × 4 K = 16 | 3 | K action 선정 |
| 실험 4 | 후보 수에 따라 결정 | 3 | 온라인 튜닝 동기 |
| 실험 5 | 대표 정책 및 workload | 3 | 결정 원인 분석 |
| 실험 6 | 4 workloads × 5 policies = 20 이상 | 5 | 최종 비교 |

실험 1~3 결과로 action 후보를 먼저 축소한 뒤 실험 4를 진행하여 전체 Cartesian product의 실행 비용을 줄인다.

## 7. Q-table 설계와 실험 결과의 연결

- Action 후보는 실험 1~3에서 유효성이 확인된 `(α, strength, K)` 조합으로 구성한다.
- 모든 경계와 출력값을 독립 action으로 두지 않고 세 개의 압축된 축으로 표현한다.
- 실험 4의 overwrite-time 구간을 state 설계의 근거로 사용한다.
- Reward는 고정 host-write window에서 측정한 GC write 비율을 사용한다.

예시 reward는 다음과 같다.

\[
r_t=-\frac{GCPageWrites_t}{HostPageWrites_t}
\]

Host write가 거의 없는 window에서는 reward 갱신을 보류하여 분모 불안정을 방지한다.

## 8. 통계 및 결과 표현

- Pilot ablation은 조합당 3회, 최종 비교는 최소 5회 반복한다.
- 평균과 95% 신뢰구간 또는 median과 IQR을 함께 제시한다.
- 동일 workload 비교에는 동일 seed를 사용한다.
- WAF뿐 아니라 `GCPageWrites / GCCount`를 같이 제시하여 개선 원인을 구분한다.
- CAT 구현의 line 전체 scan 비용은 WAF와 분리하여 selection overhead로 보고한다.

권장 결과 그림은 다음과 같다.

1. Workload별 α-WAF 곡선
2. 출력 강도별 WAF 및 평균 victim vpc
3. K별 WAF와 AgeLevel histogram
4. Overwrite period에 따른 최적 α 이동
5. RL action timeline과 victim 특성 변화
6. 전체 정책의 workload별 WAF 막대그래프

## 9. 성공 판정 기준

- 실험 1~3 중 최소 하나의 축에서 설정에 따른 반복 가능한 WAF 차이가 나타난다.
- 실험 4에서 두 개 이상의 workload 또는 period가 서로 다른 최적 설정을 갖는다.
- 실험 5에서 RL의 action 변화가 victim age/vpc/copy 변화로 설명된다.
- 실험 6에서 RL-tuned 정책이 CAT Original보다 평균 WAF를 낮추고, Greedy 대비 손실 workload 수를 줄인다.
- RL 성능이 offline oracle에 근접하면서 throughput 또는 p99 latency를 심각하게 악화시키지 않는다.

## 10. 해석 시 주의사항

- 본 결과는 hot/cold redistribution이 없는 Fig. 7 기반 victim-selection 결과이다.
- Greedy가 일부 workload에서 가장 좋은 것은 실패가 아니라 uniform 또는 짧은 age workload의 특성을 보여주는 결과다.
- RocksDB의 compaction write amplification과 FTL GC write amplification을 혼동하지 않는다.
- Workload마다 사용 공간이 달라지면 WAF 비교가 왜곡되므로 FTL preconditioning 상태와 filesystem 사용량을 함께 기록한다.
- CAT는 line scan, Greedy는 priority queue를 사용하므로 처리량 차이를 victim 정책 자체의 WAF 효과와 분리한다.
