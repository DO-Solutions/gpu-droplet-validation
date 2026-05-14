# Translate `dcgmi diag -r N -j` output to the tap-reporter result schema.
#
# Inputs (via --arg/--argjson):
#   $suite — suite name string, e.g. "dcgm-diag"
#   $rc    — integer exit code from dcgmi
#
# Output: { suite: $suite, tests: [...] }
#
# Strategy: dcgmi 4.x emits a nested document under "DCGM Diagnostic" whose
# structure has shifted slightly across point releases. Walking the tree for
# every object that carries a "status" field captures every plugin result
# regardless of how the parent containers are named, and then we attach
# the closest meaningful "name" / "test_name" we can find for diagnostics.

def status_to_point($name; $gpu_ids; $warnings; $info):
  ($name // "unknown") as $n
  | ($gpu_ids // "all") as $g
  | (.status // "Unknown") as $s
  | (
      if ($s | ascii_downcase) | IN("pass","ok") then
        { ok: true,  directive: null, diag_extra: null }
      elif ($s | ascii_downcase) | IN("skip","skipped","n/a","not_applicable") then
        { ok: true,  directive: "SKIP \($s)", diag_extra: null }
      else
        { ok: false, directive: null, diag_extra: { status: $s } }
      end
    ) as $verdict
  | {
      ok: $verdict.ok,
      name: "\($n) [gpus=\($g)]",
      directive: $verdict.directive,
      diagnostic: (
        ($verdict.diag_extra // {})
        + (if $warnings == null or ($warnings | length) == 0 then {} else { warnings: $warnings } end)
        + (if $info == null or ($info | length) == 0 then {} else { info: $info } end)
        | if (. | length) == 0 then null else . end
      )
    };

# Find every result object in the tree (anything with a "status" field).
[ .. | objects | select(has("status")) ] as $results

# Pull the most useful "name" for each result by walking the path back up;
# fall back to fields on the result itself.
| ($results
    | map(
        . as $r
        | (.test_name // .name // .plugin_name // .category // "dcgm test") as $n
        | (.gpu_ids // .gpu_id // null) as $g
        | (.warnings // .warning // null) as $w
        | (.info // null) as $i
        | $r | status_to_point($n; $g; $w; $i)
      )
  ) as $points

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
      (if ($points | length) > 0 then $points
       else [{
         ok: false,
         name: "dcgmi diag produced parseable results",
         directive: null,
         diagnostic: { raw_path: "/results/dcgm-diag_raw.json", reason: "no status fields found in JSON tree" }
       }] end)
    )
  }
