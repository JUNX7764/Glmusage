import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class QuotaCycleHistoryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.binary = Path(cls.tmp.name) / "quota-history-tests"
        subprocess.run(["swiftc", str(ROOT / "Sources/GLMQuotaCycleHistory.swift"),
                        str(ROOT / "Sources/GLMQuotaCycleContext.swift"),
                        str(ROOT / "Sources/GLMQuotaCycleStore.swift"),
                        str(ROOT / "Sources/GLMQuotaCycleCoordinator.swift"),
                        str(ROOT / "Sources/GLMQuotaCycleHistoryView.swift"),
                        str(ROOT / "tests/fixtures/quota-cycle-history/main.swift"),
                        "-o", str(cls.binary)], cwd=ROOT, check=True, timeout=120)

    def case(self, name):
        result = subprocess.run([str(self.binary), name], cwd=ROOT,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: " + name, result.stdout)

    def test_first_observation(self):
        self.case("firstObservation")

    def test_same_window_and_validation(self):
        self.case("sameWindow")

    def test_unknown_change(self):
        self.case("unknownChange")

    def test_natural_and_gap(self):
        self.case("naturalAndGap")

    def test_specification_change(self):
        self.case("specificationChange")

    def test_candidate_timeout_and_replay(self):
        self.case("candidateTimeout")

    def test_partition_and_attribution(self):
        self.case("partitionAndAttribution")

    def test_capture_gate(self):
        self.case("captureGate")

    def test_week_card_evidence(self):
        self.case("weekCardEvidence")

    def test_restored_operation_and_other_card(self):
        self.case("restoredOperation")

    def test_store_safety(self):
        self.case("storeSafety")

    def test_store_nested_and_symlink(self):
        self.case("storeNestedAndSymlink")

    def test_coordinator_isolation(self):
        self.case("coordinatorIsolation")

    def test_ambiguous_changes_remain_pending(self):
        self.case("ambiguousPending")

    def test_history_paging_and_refresh(self):
        self.case("historyPaging")

    def test_chart_geometry(self):
        self.case("chartGeometry")

    def test_percentage_below_each_date(self):
        self.case("chartPercentageLabels")

    def test_short_history_right_aligned(self):
        self.case("shortHistoryRightAligned")

    def test_compact_cycle_wording(self):
        self.case("compactCycleWording")

    def test_clock_rollback_pending(self):
        self.case("clockRollbackPending")

    def test_thousand_record_store_round_trip(self):
        self.case("thousandRecords")

    def test_coordinator_heartbeat_and_write_failure(self):
        self.case("coordinatorHeartbeat")

    def test_pending_continuity(self):
        self.case("pendingContinuity")

    def test_rollback_evidence_retained(self):
        self.case("rollbackEvidence")

    def test_operation_monotonic_retry(self):
        self.case("operationMonotonic")

    def test_plan_level_enrichment_and_missing(self):
        self.case("planLevelEnrichment")

    def test_store_invalid_sequence(self):
        self.case("invalidStoreSequence")

    def test_ordered_load_and_stale_callback(self):
        self.case("orderedLoad")

    def test_api_key_attribution_defence(self):
        self.case("apiKeyAttributionDefence")

    def test_old_connection_operation_isolation(self):
        self.case("oldConnectionOperation")

    def test_small_rebound_pending(self):
        self.case("smallReboundPending")

    def test_rollback_then_small_rebound_store(self):
        self.case("rollbackThenSmallReboundStore")

    def test_operation_invalid_state(self):
        self.case("operationInvalidState")
