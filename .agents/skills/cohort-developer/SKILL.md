---
name: cohort-developer
Description: >
  Given a clinical definition of a phenotype, develop an executable cohort definition in an iterative process of conceptual design, implementation in Capr, and evaluation. 
  Use when the user asks to develop a phenotype algorithm or cohort definition.
---

# Develop a cohort for a given phenotype

Based on the clinical definition of a phenotype, develop an operational definition that can be executed against a database in the OMOP Common Data Model (CDM). The implementation will use the Capr R package to generate the required OMOP JSON.

## Background

Data in observational healthcare databases (insurance claims, electronic health records) are not collected for research purposes. Important variables, such as health outcomes of interest, must be inferred using operational definitions. These definitions contain concept sets (OMOP vocabulary concept IDs) for diagnoses, procedures, measurements, drugs, and visit types, along with the temporal logic to combine them.  

## Prerequisites

- Requires a **clinical definition** of the phenotype, describing the clinical intent (the "what"). If a clinical definition is not provided, launch the interactive `clinical-definition-refiner` first.
- Requires the **phenotype name**. If not provided, derive it from the clinical definition.
- **Reference Material:** Read `CAPR_REFERENCE.md` (part of the capr-cohort-implementer skill) to understand the exact structure and syntax of Capr cohort definitions in R.

## Agent Workflow

1. **Conceptual Design:** Develop an initial best-guess cohort definition based on clinical knowledge. Outline the required OMOP concept sets (diagnoses, procedures, drugs) and the temporal logic.
2. **Implementation:** Write the R code using the Capr package to define the cohort and compile it into OMOP JSON.
3. **Evaluation:** Pass the generated JSON to the `evaluate_cohort` tool. Review the returned cohort counts across available databases.
4. **Iteration:** Compare the returned cohort size with clinical expectations.
    - If the count is **too low** (e.g., 0): Make the definition broader/more sensitive by removing constraints or expanding concept sets. 
    - If the count is **too high**: Make the definition more specific by adding constraints (e.g., requiring a diagnosis to occur during an inpatient visit, or requiring a subsequent treatment).
    - Re-run steps 2 and 3 with the adjusted logic.
5. **Termination & Output:** Stop when the cohort size aligns with expectations, OR after a maximum of 3 evaluation attempts. Present the user with the final Capr R code, the generated JSON, and a summary of the evaluation results.

## Heuristics for Initial Design

Think about how a phenotype plays out in a real-world healthcare setting:
* What interactions would the patient have with the healthcare system before, during, and after onset? 
* What diagnoses, visits, procedures, or prescriptions would be recorded in *both* administrative claims and EHRs? 
* Leverage Capr's structure to balance logic. Aim for a Positive Predictive Value (PPV) and sensitivity greater than 80%.
