# Translate `dcgmi diag -r N -j` output to the tap-reporter result schema.
#
# Inputs (via --arg/--argjson):
#   $suite — suite name string, e.g. "dcgm-diag"
#   $rc    — integer exit code from dcgmi
#
# Output: { suite: $suite, tests: [...] }
#
# dcgmi 4.x emits a nested document under "DCGM Diagnostic" containing
# test_categories[].tests[], where each test has a real plugin name
# (software / diagnostic / memory / pcie / targeted_power / targeted_stress),
# a results[] array with one entry per GPU, and a test_summary with the
# overall status. We emit one TAP point per test (aggregated across GPUs).

def is_pass($s): ($s // "Unknown" | ascii_downcase) | IN("pass","ok");
def is_skip($s): ($s // "Unknown" | ascii_downcase) | IN("skip","skipped","n/a","not_applicable");
def is_ok_class($s): is_pass($s) or is_skip($s);

def test_to_point:
  . as $t
  | (.name // "unknown") as $n
  | (.test_summary.status // "Unknown") as $summary_status
  | ((.results // []) | map(.status // "Unknown")) as $result_statuses
  | (
      ($result_statuses | all(is_ok_class(.)))
      and is_ok_class($summary_status)
    ) as $ok
  | (
      ($result_statuses | all(is_skip(.)))
      and is_skip($summary_status)
      and (($result_statuses | length) > 0)
    ) as $all_skip
  | (
      (.results // [])
      | map(select((.status // "Unknown") as $s | (is_ok_class($s) | not)))
      | map({
          gpu: .entity_id,
          status: (.status // "Unknown"),
          warnings: (.warnings // null),
          info: (.info // null)
        } | with_entries(select(.value != null)))
    ) as $failed_gpus
  | {
      ok: $ok,
      name: $n,
      directive: (if $all_skip then "SKIP \($summary_status)" else null end),
      diagnostic: (
        if $ok then null
        else {
          status: $summary_status,
          failed_gpus: $failed_gpus
        }
        end
      )
    };

((.["DCGM Diagnostic"].test_categories // []) | map(.tests // []) | add // []) as $tests

| {
    suite: $suite,
    tests: (
      [{
        ok: ($rc == 0),
        name: "dcgmi diag exit code == 0",
        directive: null,
        diagnostic: (if $rc == 0 then null else { exit_code: $rc } end)
      }]
      +
      (if ($tests | length) > 0 then ($tests | map(test_to_point))
       else [{
         ok: false,
         name: "dcgmi diag produced parseable results",
         directive: null,
         diagnostic: { raw_path: "/results/dcgm-diag_raw.json", reason: "no tests found under DCGM Diagnostic.test_categories" }
       }] end)
    )
  }
