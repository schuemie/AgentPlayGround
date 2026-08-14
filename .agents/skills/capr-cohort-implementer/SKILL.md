---
name: capr-cohort-implementer
description: >
  Define an OHDSI cohort as Capr R code.
  Use when needing to build, a cohort definition, phenotype, or study population using Capr, 
  R, or OHDSI/Atlas cohort JSON.
---

# Implement a cohort using Capr

Translate an idea for a cohort definition into a validated Capr R script that compiles to
OHDSI (Circe/Atlas-compatible) cohort JSON.

## Requirements

- R with the **Capr** package installed (CirceR comes with it). No database connection is needed
  at any point — Capr builds and serializes cohort definitions entirely in memory.
- **`CAPR_REFERENCE.md`** (same directory as this file). Read it before writing any code; it is
  the only source of truth for the Capr API.

## Non-Negotiable Rules

1. **Use only functions and arguments documented in `CAPR_REFERENCE.md`.** If something seems
   missing, say so — do not improvise API.
2. **Never write a concept ID from memory.** This includes clinical concepts and type / unit /
   status / provider-specialty IDs. Use the Hecate tools if needed to find individual concepts.
3. Concept sets **must** be constructed using the create_concept_set tool. This tool generates
   Capr code that can be added to the overall code. 
4. **Always produce the function-form output** described below, even for a one-off cohort.
5. **Always execute the generated file before delivering it.** Code that has not run is not done.
6. **Say so when the cohort is not expressible in Capr/Circe.** Check every request against the
   wrong-tool signals in `CAPR_REFERENCE.md` before writing code. A definition that compiles but
   means something different from what the user asked for is worse than no code — never deliver
   a silent approximation; state the mismatch and propose the decomposition pattern instead.

## Workflow

### Step 1 — Generate the cohort function

Every deliverable is one R file with this structure:

```r
library(Capr)

#' Build the <phenotype> cohort definition
#'
#' <one-paragraph restatement of the cohort logic in plain English>
#'
#' @return A Capr Cohort object; serialize with writeCohort() or compile()
createT2dmCohort <- function() {
  t2dmCs <- cs(descendants(201826), name = "type 2 diabetes")
  insulinCs <- cs(descendants(1596977), name = "insulin")
  cohort(
    entry = entry(
      conditionOccurrence(t2dmCs),
      observationWindow = continuousObservation(priorDays = 365L),
      primaryCriteriaLimit = "First"
    ),
    attrition = attrition(
      "no prior insulin" = withAll(
        exactly(0, drugExposure(insulinCs),
                duringInterval(eventStarts(-Inf, -1)))
      ),
      expressionLimit = "First"
    ),
    exit = exit(endStrategy = observationExit()),
    era = era(eraDays = 0L)
  )
}

# ---- Example usage ----------------------------------------------------------
cohortDef <- createT2dmCohort()
writeCohort(cohortDef, "t2dm_cohort.json")
```

Contract:

- **Fully define the index event inside `entry()`.** Every restriction that determines which
  event can index goes on the entry Query itself — attributes and `nestedWithAll()`/
  `nestedWithAny()` correlated criteria; never `additionalCriteria`. `attrition()` rules run
  against the candidate events that survive `primaryCriteriaLimit` — use them to screen those
  candidates (demographics, prior history, washout), not to define which event can index.
  Putting index qualifiers in `attrition()` with `primaryCriteriaLimit = "First"` silently drops
  people whose first raw event fails the qualifier (see the reference's "Fully define the index
  event in entry()").
- **Return the `Cohort` object.** Serialization happens in the example block, not in the function.

### Step 3 — Validate by executing

1. Run the file: `Rscript <file>.R`. It must run end-to-end — including the placeholder example
   block — and write the JSON file. No database is required.
2. If it errors: fix the code using `CAPR_REFERENCE.md` (the error usually means an argument or
   function outside the documented API) and re-run. If the same error survives three fix
   attempts, stop and show the user the error instead of thrashing.
3. Confirm Circe accepts the output — this catches structural problems R execution cannot:

   ```r
   Rscript -e 'json <- paste(readLines("t2dm_cohort.json"), collapse = "\n");
     invisible(CirceR::buildCohortQuery(CirceR::cohortExpressionFromJson(json),
       CirceR::createGenerateOptions(generateStats = FALSE)))'
   ```

   Success = SQL generates without error. Do not deliver a cohort that fails this check.

