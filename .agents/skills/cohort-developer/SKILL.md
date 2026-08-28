---
name: cohort-developer
Description: >
  Given a clinical definition of a phenotype, develop an executable cohort definition in an iterative process of conceptual design, implementation in Capr, and evaluation. 
  Use when the user asks to develop a phenotype algorithm or cohort definition.
---

# Develop a cohort for a given phenotype

Based on the Clinical Definition of a phenotype, develop an operational definition that can be executed against a database in the OMOP Common Data Model (CDM). The implementation uses the Capr R package. The `generate_cohort` and `evaluate_cohort` tools compile the Capr definition to OMOP JSON **server-side**, so you submit Capr R code — not JSON — to them.

## Background
Data in observational healthcare databases (insurance claims, electronic health records) are not collected for research purposes. Important variables, such as health outcomes of interest, must be inferred using operational definitions. These definitions contain concept sets (OMOP vocabulary concept IDs) for diagnoses, procedures, measurements, drugs, and visit types, along with the temporal logic to combine them.  

## Prerequisites
- Requires a **Clinical Definition** of the phenotype, describing the clinical intent (the "what"). If a clinical definition is not provided, launch the interactive `clinical-definition-refiner` first.
- Requires the **phenotype name**. If not provided, derive it from the clinical definition.
- **Reference Material:** Read `CAPR_REFERENCE.md` (in the same folder as this file) to understand the exact structure and syntax of Capr cohort definitions in R.

## Agent Workflow

### Phase 1: Conceptual Design
1. **Retrieve available concept sets:** Use the `list_concept_sets` tool to identify relevant OMOP concept sets for the phenotype and their person counts. Concept sets with 0 counts are likely unhelpful.
2. **Create additional concept sets:** At any time you can create additional concept sets using the `create_new_concept_set` tool.
2. **Apply Clinical & Database Knowledge:** Develop an initial best-guess cohort definition based on clinical reality and your knowledge of EHRs and Claims data. Outline the required concept sets and temporal logic. Use `get_concept_sets_capr` to fetch Capr `cs(...)` code and per-domain person counts for the pre-created concept sets you need.

### Phase 2: Implementation & Generation (Unlimited Attempts)
*You may iterate through this phase as many times as needed to get reasonable person counts and attrition rates before proceeding to KEEPER evaluations.*
3. **Implementation:** Write the R code using the Capr package to define the cohort (see `CAPR_REFERENCE.md`). 
	- **Submission format (required):** `caprCode` must be a **single `cohort(...)` expression** with every concept set **inlined** as the first argument of its domain query, and **no assignments or helper variables**. The tool compiles it in an isolated sandbox that rejects anything outside the documented Capr API. Do **not** pass JSON. You can use the `validate_capr` tool to validate the code if needed.
	- Each `cs(...)` snippet from `get_concept_set_capr` needs a `name = "..."` added when you inline it.
4. **Cohort Generation:** Pass the **Capr cohort definition as R code** to the `generate_cohort` tool to instantiate the cohort in the database. This tool returns a **cohort ID**.
5. **Count Verification:** Call the `get_cohort_count` tool using the returned **cohort ID** to get cohort counts (split by inclusion rules). If the counts seem unreasonable (e.g., they are 0, or attrition is too high), adjust your Capr code and repeat Steps 3-5.

### Phase 3: KEEPER Evaluation (MAXIMUM 3 ATTEMPTS)
*To strictly avoid overfitting to the reference set, you are limited to a maximum of 3 calls to `evaluate_cohort`.*
6. **Evaluate:** Once counts are reasonable, call the `evaluate_cohort` tool using the **cohort ID** to get a summary of the cohort's operating characteristics against the KEEPER reference set. 
7. **Patient Profiling:** To understand the performance, call the `sample_patient_profile` tool (using the **cohort ID**) to review individual patient profiles.
8. **Refine or Terminate:** Adjust the cohort definition based on evaluation results. Return to Phase 2 to regenerate the cohort. You must **STOP** when the operating characteristics are sufficient (aiming for PPV and Sensitivity > 80%), OR after you have executed Step 6 exactly 3 times.

## Final Output
Present the user with the final Capr R code and a summary of the evaluation results. If the user wants the OMOP JSON, produce it with the `convert_capr_to_json` tool, saving it to file immediately. There is no need to verify the JSON.

## Heuristics for Initial Design
Think about how the phenotype plays out in a real-world healthcare setting:
* **EHR vs. Claims:** How does the data capture differ? (e.g., Claims will have precise billing diagnoses but may lack lab results; EHRs will have rich clinical measurements but may have missing data if the patient went out of network). Build logic that bridges these gaps.
* **Patient Journey:** What interactions would the patient have with the healthcare system before, during, and after onset? 
* **Operational Accuracy:** What operational definition would accurately reflect the phenotype as described in the Clinical Definition? Leverage Capr's structure to balance logic. 

## Capr Rules
1. **Use only functions and arguments documented in `CAPR_REFERENCE.md`.** If something seems missing, say so — do not improvise API.
2. **Never write a concept ID from memory.** This includes clinical concepts and type/unit/status/provider-specialty IDs. Use the Hecate tools if needed to find individual concepts.
3. Concept sets **must** be constructed using the `get_concept_set_capr` tool. This tool generates Capr code that can be added to the overall code. 
4. **Say so when the cohort is not expressible in Capr/Circe.** Check every request against the wrong-tool signals in `CAPR_REFERENCE.md` before writing code. A definition that compiles but means something different from what the user asked for is worse than no code — never deliver a silent approximation; state the mismatch and propose the decomposition pattern instead.

## Creating additional concept sets
Provide a name and a description for the concept set. The following rules apply to the description:
- Provide a comprehensive paragraph (minimum 3–4 detailed sentences).
- Do NOT provide a generic dictionary definition, tautology, or simple repetition of the name.
- Define the concept set strictly in isolation based on its intrinsic clinical, pathophysiological, laboratory, or anatomical properties.
- Do NOT mention the phenotype for which we are developing a cohort definition.
- Do NOT explain why the concept set is relevant to the phenotype, how it acts as a risk factor, or how it alters clinical management.
- Explicitly define what the concept set encompasses and what it excludes.
- Clarify key clinical distinctions, including:
  - Chronicity (e.g., acute vs. chronic)
  - Etiology (e.g., primary vs. secondary, acquired vs. congenital)
  - Severity or Staging (e.g., eGFR thresholds, laboratory markers, structural criteria)
  - Related conditions (e.g., dialysis/transplant status, underlying systemic etiologies)
