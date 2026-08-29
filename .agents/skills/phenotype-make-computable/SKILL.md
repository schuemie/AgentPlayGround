---
name: phenotype-make-computable
description: Create a review-gated OHDSI cohort definition from a well-specified narrative cohort statement by calling StudyAgent's phenotype_make_computable ACP endpoint. Use when a user wants a validated function-form Capr R definition and Circe JSON, or needs clarification or concept-set review before creating one.
---

# Phenotype make computable

If the user has not provided a URL for the StudyAgent ACP service,  you must first prompt the user for the url for the StudyAgent ACP service which should be http://<host>:<port> whith <host> as 'localhost', '0.0.0.0', or a remote host and <port> as 8765 or another valid port. If the user is not sure, stop with a message that this tool requires that information. If they provide the url, call `POST ${STUDY_AGENT_ACP_URL:-http://<host>:<port>}/flows/phenotype_make_computable`. Retain the narrative, confirmed scope, and reviewed concept sets locally and resubmit them in each emission request. Large review sessions are immutable but short-lived; download their review package for durable continuation.

Never send PHI or row-level data. Never invent scope decisions, concept IDs, domain policies, or Capr/Circe code.

## Non-negotiable review gates

- Do not infer omitted scope. If the user did not explicitly provide every scope decision, submit only a clarification request with `confirmed_scope: false`.
- When a narrative or scope requires Visit overlap, require both `visit_overlap: true` and an explicit `visit_overlap_mode` of `entry` or `attrition`. Preserve that exact mode in every later request; never rely on a default. `entry` makes overlap part of the qualifying event, while `attrition` applies it as an inclusion restriction.
- If narrative wording suggests earliest/first but the user supplies `entry_limit: "All"`, identify the tension and ask whether repeated qualifying events are intended. Do not silently change the supplied limit.
- Use `multi_domain_entry_policy` only when one reviewed concept set itself spans multiple event domains. Do not add it to separate Condition-index and Visit-supporting sets; Visit overlap is expressed by `visit_overlap` and `visit_overlap_mode`.
- Treat `needs_clarification` and `needs_concept_review` as terminal responses for the current turn. Show the result, ask the user for the missing decision or review, and stop. Do not issue another ACP request in that turn.
- Do not use `concept_review_mode: "provided_only"` unless a later user message explicitly supplies the exact reviewed `concept_sets` object or explicitly approves that exact object, including every item's descendant, mapped, and exclusion policies.
- Tool-execution approval authorizes only the local command. It is never clinical, scope, or concept-set approval.
- Do not interpret “continue”, silence, a candidate's rank, a parent-concept relationship, or an LLM proposal as approval. Never select a candidate or choose `include_descendants` on the user's behalf.
- After any ACP request returns a JSON body, do not retry it automatically. Treat the JSON as the response, render it faithfully, and stop when its status requires review. If it cannot be parsed, show the raw body and ask the user whether to retry.
- If the one permitted curl command is still running, wait/poll that same command. Do not launch a second curl, even to check progress. A client timeout is not ACP JSON; report it and ask whether a later-turn retry is authorized.
- Do not emit, save, or display Capr/Circe artifacts before explicit concept-set approval.
- A vocabulary result is a bounded lexical retrieval, not a complete concept set. Never call the returned slice “all matches” unless `matched_count` is exact and equals `returned_count`.
- Serialize every ACP request body with a JSON serializer or a safely written JSON payload file passed through `curl --data-binary @<file>`; never hand-compose a single-quoted shell JSON literal. This prevents narrative punctuation or structured scope values from changing the request or breaking shell parsing.

## Workflow

1. Send the narrative-only clarification request below whenever scope is incomplete. Present the returned checklist verbatim enough for the user to decide.
2. Keep `index_event` as the user's plain clinical term (for example, `"Cirrhosis of liver"`). Put event selection only in `entry_limit` (`"First"` or `"All"`); do not rewrite the event as “first qualifying … condition occurrence”. Use that same plain term as the matching key in `criterion_domains`. Before a broad medication or diagnosis lookup, ask whether the intended frame is an ingredient, clinical drug, branded product, dose form, or all related records. If the user also specifies a vocabulary such as RxNorm, preserve it as `criterion_vocabularies: {"<same criterion label>": ["RxNorm"]}`. Do not claim a vocabulary-restricted search unless returned provenance reports that vocabulary constraint and its filter status. Do not pass a prose instruction such as “OMOP standard concepts for …” literally to the lexical vocabulary query. For a separate supporting Condition occurrence, ask whether `First` means the first raw index record or the first index record satisfying the condition. The currently supported raw-index form uses `multi_domain_entry_policy: "supporting_evidence_only"`, leaves `windows: "none"`, and records only this structured field—never prose in `windows`:
   ```json
   "supporting_condition_occurrence": {"concept_set": "<review lane label>", "start_days": -180, "end_days": 0, "anchor": "index_start"}
   ```
   It emits the Condition occurrence as attrition/supporting evidence. For “first qualifying index record,” stop and request an emitter mode; do not approximate it as attrition.
3. After the user explicitly confirms every scope decision, call with `confirmed_scope: true` and `concept_review_mode: "required"`. State per lane: `matched_count` and whether it is exact/not available, `returned_count`, `limit`, `truncated`, and ordering. If `truncated` is true, say the candidate CSV is only a bounded retrieval slice. If `large_result_guidance` is present, present its narrow-search/Atlas advice before asking for review. If the returned count is 10 or fewer, display every returned candidate in one review table with concept-set lane, concept ID, name, domain, vocabulary, concept class, raw OMOP `standard_concept`, and Standard / Classification / Non-standard / Unknown status. Treat the lane as review provenance, not a user-approved policy. Do not choose or rank a concept. End the turn.
4. If the returned count exceeds 10, do not dump the candidate table into the terminal. A normal `review_delivery: "auto"` response supplies `review_delivery: "session"`, a `review_id`, and `review_urls`. Before asking permission to download, state exactly what that CSV contains, lane by lane: `<lane>: returned R of M exact matches` (or `matched count unavailable`), and explicitly label every truncated lane. If no lane is truncated, say “This download is complete: N of N returned candidates” before asking permission. If any lane is truncated, say “Downloading this session now writes only the returned slice: N rows total; it is not a complete concept-set candidate export.” Then offer the applicable next action before requesting any download:
   - if every exact truncated lane has at most 100 matches, offer a fresh complete session with `candidate_limit` equal to the largest lane count;
   - if one or more exact lanes exceed 100, state that a fresh session can return at most 100 per lane, identify which lanes would remain truncated, and offer either the current slice, the maximal 100-per-lane session, or narrowing/Atlas import;
   - if counts are unavailable, state that completeness cannot be determined and offer the bounded slice, a narrower frame, or Atlas/explicit IDs.
   If the user chooses a slice, repeat its precise lane counts in the download permission. If the user chooses a complete or maximal fresh session, make that one new review request first and then state whether its CSV is complete before requesting download. If the user declines, offer a paginated display through `review_urls.candidates` and state exactly `Returned N candidates; showing M of N`, identifying omitted IDs. Never describe a partial table as “all candidates” or a complete matched set. Do not proceed to selection.
5. After permission, download both `review_urls.candidates_csv` and `review_urls.manifest` to the user-specified review directory, or `./phenotype-review/` when no path is specified. Use sibling names `<safe-narrative-slug>_concept_review.csv` and `<safe-narrative-slug>_concept_review_manifest.json`. The CSV contains one frozen candidate per row. `proposed_*` fields record only a provisional policy actually suggested by the LLM; blank means no proposed policy. State both written paths, the human-readable `review_expires_at`, and that the package is unreviewed. Then give the user this concise review handoff:
   - Edit only `review_*` columns; mark chosen cells with `x` and leave all other review cells blank.
   - For a row, mark either `review_include_concept` or `review_exclude_concepts`, never both. Descendants/mapped marks require the corresponding include/exclude root mark.
   - Blank review fields mean omit the candidate. Prefer rows marked `Standard` unless the user explicitly wants a non-standard source concept or uses the matching policy; `include_mapped` remains an explicit separate choice. `not_assessed_retrieval_context` is retained evidence, not an automatic choice; include it only deliberately.
   - Preserve the manifest beside the CSV. Keep each frozen `concept_set_name` lane intact; it determines the emitted set grouping. For a single unlabeled lane, also tell the agent the intended fallback concept-set name. Save the CSV, then tell the agent its path. The agent will validate and display the exact submission object for explicit approval.
   - Before expiry, the agent can read the session URLs. After expiry or ACP restart, the saved CSV plus manifest still supports validation and submission; only an undownloaded session requires a new review request.
   Do not fabricate a CSV from a truncated terminal response.
6. Treat a user-edited CSV as review input, not submission approval. When the user points to it, run `python3 .agents/skills/phenotype-make-computable/scripts/phenotype_review_csv_to_concept_sets.py --csv <path> --manifest <adjacent-manifest-path> --approval-json <path>.approval.json --approval-csv <path>.approval.csv` from the AgentPlayGround repository root (add `--concept-set-name <user-approved-fallback>` only when selected rows have no frozen lane name). For more than 20 selected items, show the human-readable preview table and the approval JSON path plus SHA-256; request approval of that exact file/digest rather than pasting or summarizing a large JSON object. For 20 or fewer, render the exact object inline. The reader accepts `x` case-insensitively and blank as false, rejects contradictory/incomplete markings, groups selected rows by their frozen `concept_set_name` and domain, and emits both policy-bearing `concept_sets` and `approval_preview`. First render the set grouping (name, domain, selected count), then render every `approval_preview` row in a human-readable table with concept-set name, concept ID, concept name, domain, raw OMOP `standard_concept`, standard-concept status, policy, assessment status, precision eligibility, and relationship evidence before showing the exact emitted `concept_sets` object. Highlight manually included `not_assessed_retrieval_context` rows; those rows are never automatic choices. Request explicit approval before calling `provided_only`, even when the review session has expired.
7. When the user explicitly asks for bulk CSV marks, use `.agents/skills/phenotype-make-computable/scripts/phenotype_review_csv_mark.py` with a new `--output` path; never use `awk` or field-position editing on a CSV. Then validate the resulting file as in step 6.
8. If the user instead supplies an OHDSI Atlas concept-set export or bare Atlas expression (`{"items": [...]}`), normalize it deterministically before approval: run `python3 .agents/skills/phenotype-make-computable/scripts/phenotype_external_concept_set_to_acp.py --atlas-json <path> --concept-set-name <user-approved-name>` when the JSON carries no set name, or `python3 .agents/skills/phenotype-make-computable/scripts/phenotype_external_concept_set_to_acp.py --concept-ids-file <path> --concept-set-name <user-approved-name> --domain <OMOP-domain>` for IDs. Render the resulting policy object and request explicit approval; never infer policies for pasted IDs. Mixed-domain Atlas exports require separate reviewed sets.
9. If the user explicitly asks for a provisional LLM proposal, call once with `concept_review_mode: "propose"`. Use `concept_build_mode: "grounded"` only when the user explicitly requests grounded concept building; otherwise omit it (the service defaults to `search_only`). For 10 or fewer candidates, display the complete candidate table, `concept_build` terms and step counts when present, the exact `concept_provenance` (including PHOEBE relationship expansion), every `candidate_assessment` with its precision-eligibility rationale, the complete `proposed_plan`, a policy table for every proposed concept-set item, assumptions, warnings, and proposal diagnostics. For more than 10 candidates, first display status, proposal-validation status/errors, every `proposal_advisories` entry, candidate count, assessment scope/count, and provenance counts, then ask permission to download the CSV artifact in step 5 and stop. Only after that separate permission may it fetch `review_urls.proposal` or the CSV; these GETs read the immutable review session and are not proposal retries. Label every proposal unreviewed. Search terms and relationship evidence are retrieval hints, not approved concepts or clinical decisions. Never turn that proposal into an artifact.
10. Only on a later user message that supplies or explicitly approves the exact proposed `concept_sets` object, call with `concept_review_mode: "provided_only"`. An approval to run curl or another tool is insufficient.
11. For `ok`, report the returned Capr source, Circe JSON, validation evidence, provenance, and assumptions. Display `validation.r_environment` with R version, platform, direct validation package versions (`Capr`, `CirceR`, `SqlRender`), and loaded-namespace count; make the full namespace map available on request. Describe this only as technical validation: R sourced the generated function, Capr wrote Circe JSON, and CirceR generated SQL. Do not claim clinical validity or database-level cohort validation.

## Request shapes

Use `Content-Type: application/json`. For an LLM proposal request, use `curl --max-time 120`; a successful grounded proposal can take more than 30 seconds. This changes only the client wait allowance, never the one-request/no-retry rule.

Start an incomplete narrative with this request; do not add guessed scope fields:

```json
{
  "narrative_statement": "<user narrative>",
  "confirmed_scope": false,
  "concept_review_mode": "required",
  "candidate_limit": 20,
  "concept_sets": []
}
```

After explicit scope confirmation, include the complete user-supplied `scope` and still leave `concept_sets` empty:

```json
{
  "narrative_statement": "<same narrative>",
  "confirmed_scope": true,
  "scope": {
    "index_event": "<user-confirmed event>",
    "criterion_domains": {"<event>": "<user-confirmed OMOP domain>"},
    "criterion_vocabularies": {"<event>": ["<optional user-confirmed vocabulary, e.g. RxNorm>"]},
    "entry_limit": "<First or All>",
    "prior_observation": "<integer days>",
    "index_day_boundary": "<included or excluded>",
    "windows": "<user-confirmed temporal semantics, or none for the supporting-condition mode>",
    "supporting_condition_occurrence": {"concept_set": "<Condition review lane>", "start_days": -180, "end_days": 0, "anchor": "index_start"},
    "multi_domain_entry_policy": "supporting_evidence_only",
    "exit_strategy": "<observation, end_of_observation, or fixed object>",
    "visit_overlap": false
  },
  "concept_review_mode": "required",
  "candidate_limit": 20,
  "concept_sets": []
}
```

`candidate_limit` is optional and bounded to 1–100. It changes only the returned review slice; it does not make a lexical search complete.

For a one-call LLM proposal, use the complete confirmed scope, `concept_review_mode: "propose"`, `"review_delivery": "auto"`, and an empty `concept_sets` list. Add `"concept_build_mode": "grounded"` only when the user explicitly requests the grounded vocabulary pipeline. In that mode, show `concept_build` and `concept_provenance` exactly as returned; do not treat generated terms, candidates, or the LLM plan as approval. Its response is review material only; do not resubmit it automatically. A session response is intentionally compact; preserve its `review_id` and URLs for later user-authorized read/download actions.

Only after an explicit later approval, submit a **wrapped concept set**, not an item directly in `concept_sets`:

```json
{
  "narrative_statement": "<same narrative>",
  "confirmed_scope": true,
  "scope": {"<the unchanged confirmed scope>": "..."},
  "concept_review_mode": "provided_only",
  "concept_sets": [
    {
      "name": "<user-approved name>",
      "domain": "Condition",
      "items": [
        {
          "concept_id": 123,
          "domain": "Condition",
          "include_descendants": false,
          "include_mapped": false,
          "is_excluded": false
        }
      ]
    }
  ]
}
```

Use the policies exactly as approved. Preserve exclusions as exclusions. A mixed-domain reviewed set also needs an explicit `multi_domain_entry_policy`; ask whether each domain defines entry or supports evidence and stop for the answer.

## Response handling

- `needs_clarification`: show the unresolved design choice and stop.
- `needs_concept_review`: show candidates or a provisional plan and stop.
- `ok`: present the returned artifacts and technical-validation evidence.
- `unavailable` or failed validation: display `proposal_validation_status` and every `proposal_validation_errors` entry before any summary; then surface diagnostics. Do not search logs or make another ACP request after a JSON response, and do not fabricate a partial artifact.
