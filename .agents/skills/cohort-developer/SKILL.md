---
name: cohort-developer
Description: >
  Given a clinical definition of a phenotype, develop an executable cohort definition in an iterative process of conceptual design, implementation in Capr, and evaluation. 
  Use when the user asks to develop a phenotype algorithm or cohort definition.
---

# Develop a cohort for a given phenotype

Based on the clinical definition of a phenotype, develop an operational definition that can be executed against a database in the OMOP Common Data Model (CDM). The implementation uses the Capr R package. The `generate_cohort` and `evaluate_cohort` tools compile the Capr definition to OMOP JSON **server-side**, so you submit Capr R code — not JSON — to them.

## Background

Data in observational healthcare databases (insurance claims, electronic health records) are not collected for research purposes. Important variables, such as health outcomes of interest, must be inferred using operational definitions. These definitions contain concept sets (OMOP vocabulary concept IDs) for diagnoses, procedures, measurements, drugs, and visit types, along with the temporal logic to combine them.  

## Prerequisites

- Requires a **clinical definition** of the phenotype, describing the clinical intent (the "what"). If a clinical definition is not provided, launch the interactive `clinical-definition-refiner` first.
- Requires the **phenotype name**. If not provided, derive it from the clinical definition.
- **Reference Material:** Read `CAPR_REFERENCE.md` (part of the capr-cohort-implementer skill) to understand the exact structure and syntax of Capr cohort definitions in R.

## Agent Workflow

1. **Retrieve available concept sets**. Use the `list_concept_sets` tool to identify relevant OMOP concept sets for the phenotype. Use `get_concept_set_capr` to fetch each one's Capr `cs(...)` code.
1. **Conceptual Design:** Develop an initial best-guess cohort definition based on clinical knowledge. Outline the required OMOP concept sets (diagnoses, procedures, drugs) and the temporal logic.
2. **Implementation:** Write the R code using the Capr package to define the cohort (see `CAPR_REFERENCE.md`). You do **not** compile to JSON yourself — the evaluation tools do that server-side.
3. **Evaluation:** Pass the **Capr cohort definition as R code** to the `generate_cohort` tool (the `caprCode` argument) to get cohort counts across available databases. If the counts seem reasonable, call the `evaluate_cohort` tool (same `caprCode` argument) to get a summary of the cohort's operating characteristics.
   - **Submission format (required):** `caprCode` must be a **single `cohort(...)` expression** with every concept set **inlined** as the first argument of its domain query, and **no assignments or helper variables**. The tool compiles it in an isolated sandbox that rejects anything outside the documented Capr API (no `<-`, `::`, `system`, `eval`, file/network calls, etc.). Do **not** pass JSON.
   - Each `cs(...)` snippet from `get_concept_set_capr` needs a `name = "..."` added when you inline it (Capr requires it).
4. **Iteration:** Adjust the cohort definition based on evaluation results.
5. **Termination & Output:** Stop when the operating characteristics are sufficient, OR after a maximum of 3 evaluation attempts. Present the user with the final Capr R code and a summary of the evaluation results. (If the user wants the OMOP JSON, produce it locally with `compile()` / `writeCohort()`; the evaluation tools do not return it.)

## Heuristics for Initial Design

Think about how a phenotype plays out in a real-world healthcare setting:
* What interactions would the patient have with the healthcare system before, during, and after onset? 
* What diagnoses, visits, procedures, or prescriptions would be recorded in *both* administrative claims and EHRs? 
* Leverage Capr's structure to balance logic. Aim for a Positive Predictive Value (PPV) and sensitivity greater than 80%.
