# This file runs a local MCP server, providing the functions defined here to the agent. To use, configure your 
# environment to launch the MCP server, for example by adding the following the MCP.json:
# "r-tools": {
#   "command": "Rscript",
#   "args": [
#     "--vanilla",
#     "tools/server.R"
#   ]
# }
#
# Currently requires develop version of Capr: remotes::install_github("ohdsi/Capr", ref = "develop")



requiredPackages <- c("mcptools",
                      "ellmer",
                      "dplyr",
                      "CirceR",
                      "DatabaseConnector",
                      "Keeper",
                      "CohortGenerator",
                      "stringr",
                      "ParallelLogger",
                      "jsonlite",
                      "SqlRender",
                      "keyring")
missingPackages <- requiredPackages[!(requiredPackages %in% installed.packages()[,"Package"])]
if(length(missingPackages) > 0) {
  stop("Missing packages: ", paste(new.packages, collapse = ", "))
}

library(dplyr)
library(ellmer)
library(mcptools)

connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms = "spark",
  connectionString = keyring::key_get("databricksConnectionString"),
  user = "token",
  password = keyring::key_get("databricksToken"),
  pathToDriver = "c:/Users/admin_mschuemi/jdbcDrivers" # .renviron is not read when running in VSCode
)
databaseName <- "Optum Clinformatics"
databaseDescription <- "Medical claims, pharmacy claims, lab test results, inpatient, and provider data. It includes electronic health data for over 126 million patients across the United States of America, beginning in 2007."
cdmDatabaseSchema <- "optum_extended_dod.cdm_optum_extended_dod_v4020"
cohortDatabaseSchema <- "scratch.scratch_mschuemi"
cohortTable <- "agent_test_cohort"
referenceCohortDatabaseSchema <- "scratch.scratch_all"
referenceCohortTable <- "reference_cohort_optum_extended_dod_v4020"
referenceCohortProfilesTable <- "reference_cohort_profiles_optum_extended_dod_v4020"
options(sqlRenderTempEmulationSchema = "scratch.scratch_mschuemi")

# For running Phenelope:
llmClientO3 <- ellmer::chat_azure_openai(
  endpoint = keyring::key_get("genai_openai_endpoint"),
  api_version = "2024-12-01-preview",
  model = "o3",
  credentials = function() keyring::key_get("genai_api_gpt4_key")
)
llmClient4o <- ellmer::chat_azure_openai(
  endpoint = keyring::key_get("genai_openai_endpoint"),
  api_version = "2023-03-15-preview",
  model = "gpt-4o",
  credentials = function() keyring::key_get("genai_api_gpt4_key")
)
newConceptSetsFolder <- "newConceptSets"

# Support functions and global variables -------------------------------------------------------------------------------
normalizeName <- function(name) {
  return(gsub("[^[:alnum:]]", "", tolower(name)))
}

conceptSets <- readRDS("tools/PhenelopeConceptSets.rds") |>
  mutate(normPhenotype = normalizeName(phenotype))

standardConceptSets <- readRDS("tools/StandardConceptSets.rds")

# Returns the cohort ID:
ensureCohortExists <- function(json, connection) {
  expression <- CirceR::cohortExpressionFromJson(json)
  sql <- CirceR::buildCohortQuery(expression, CirceR::createGenerateOptions(generateStats = TRUE))
  
  cohortTableNames <- CohortGenerator::getCohortTableNames(cohortTable)
  if (DatabaseConnector::existsTable(connection, cohortDatabaseSchema, cohortTable)) {
    existingCohorts <- DatabaseConnector::renderTranslateQuerySql(
      connection = connection,
      sql = "SELECT cohort_definition_id, checksum FROM @cohort_database_schema.@table;",
      cohort_database_schema = cohortDatabaseSchema,
      table = cohortTableNames$cohortChecksumTable,
      snakeCaseToCamelCase = TRUE
    )
    matchingCohortId <- existingCohorts |>
      filter(checksum ==  CohortGenerator::computeChecksum(sql)) |>
      pull(cohortDefinitionId)
    
    if (length(matchingCohortId) == 1) {
      return(matchingCohortId)
    } else {
      nextCohortId <- max(existingCohorts$cohortDefinitionId) + 1
    }
  } else {
    CohortGenerator::createCohortTables(
      connection = connection,
      cohortDatabaseSchema = cohortDatabaseSchema,
      cohortTableNames = cohortTableNames
    )
    nextCohortId <- 1
  }
  cohortDefinitionSet <- tibble(
    cohortId = nextCohortId,
    cohortName = paste("Cohort", nextCohortId),
    sql = sql,
    json = json
  )
  CohortGenerator::generateCohortSet(
    connection = connection,
    cdmDatabaseSchema = cdmDatabaseSchema,
    cohortDatabaseSchema = cohortDatabaseSchema,
    cohortTableNames = cohortTableNames,
    cohortDefinitionSet = cohortDefinitionSet,
    incremental = TRUE,
  )
  CohortGenerator::insertInclusionRuleNames(
    connection = connection,
    cohortDatabaseSchema = cohortDatabaseSchema,
    cohortDefinitionSet = cohortDefinitionSet,
    cohortInclusionTable = cohortTableNames$cohortInclusionTable
  )
  return(nextCohortId)
}

# Compile a client-supplied Capr cohort definition (R text) to Circe JSON in an isolated,
# credential-less process (Option A1 + compile-worker split). The worker validates the code
# against a strict allow-list before evaluating it; this main process — which holds the CDM
# credentials — only ever receives the compiled JSON back, and never runs the client code.
#
# Deployment note: on RStudio Connect, additionally run the worker under an OS sandbox
# (no network egress, read-only filesystem, non-root UID, CPU/memory/wall-clock limits). The
# R-level allow-list in compileWorker.R is defense-in-depth, not a complete boundary.
compileCaprViaWorker <- function(caprCode, timeoutSeconds = 60) {
  workerPath <- normalizePath(file.path("tools", "compileWorker.R"), mustWork = TRUE)
  callr::r(
    func = function(code, worker) {
      suppressPackageStartupMessages(library(Capr))
      source(worker, local = TRUE)
      validateAndCompileCapr(code)
    },
    args = list(code = caprCode, worker = workerPath),
    timeout = timeoutSeconds,
    env = callr::rcmd_safe_env(),
    show = FALSE
  )
}

getCounts <- function(conceptSetSql) {
  connection <- DatabaseConnector::connect(connectionDetails)
  on.exit(DatabaseConnector::disconnect(connection))
  sql <- "
    WITH concept_set AS (
      @concept_set_sql
    ),
    domain_persons AS (
      SELECT DISTINCT
        person_id,
        'Condition' AS domain_id
      FROM @cdm_database_schema.condition_occurrence
      WHERE condition_concept_id IN (
        SELECT concept_id
        FROM concept_set
      )
       
      UNION ALL
       
      SELECT DISTINCT
        person_id,
        'Procedure' AS domain_id
      FROM @cdm_database_schema.procedure_occurrence
      WHERE procedure_concept_id IN (
       SELECT concept_id
       FROM concept_set
      )
       
      UNION ALL
       
      SELECT DISTINCT
       person_id,
        'Drug' AS domain_id
      FROM @cdm_database_schema.drug_exposure
      WHERE drug_concept_id IN (
       SELECT concept_id
       FROM concept_set
      )
       
      UNION ALL
       
      SELECT DISTINCT
       person_id,
        'Measurement' AS domain_id
      FROM @cdm_database_schema.measurement
      WHERE measurement_concept_id IN (
        SELECT concept_id
        FROM concept_set
      )
       
      UNION ALL
       
      SELECT DISTINCT
       person_id,
       'Observation' AS domain_id
      FROM @cdm_database_schema.observation
      WHERE observation_concept_id IN (
        SELECT concept_id
        FROM concept_set
      )
    )
    SELECT
      COUNT(DISTINCT CASE
        WHEN domain_id = 'Condition' THEN person_id
      END) AS condition_persons,
       
      COUNT(DISTINCT CASE
        WHEN domain_id = 'Procedure' THEN person_id
      END) AS procedure_persons,
       
      COUNT(DISTINCT CASE
        WHEN domain_id = 'Drug' THEN person_id
      END) AS drug_persons,
       
      COUNT(DISTINCT CASE
        WHEN domain_id = 'Measurement' THEN person_id
      END) AS measurement_persons,
       
      COUNT(DISTINCT CASE
        WHEN domain_id = 'Observation' THEN person_id
      END) AS observation_persons,
       
      COUNT(DISTINCT person_id) AS overall_persons
      FROM domain_persons;
  "
  counts <- DatabaseConnector::renderTranslateQuerySql(
    connection = connection,
    sql = sql,
    concept_set_sql = SqlRender::render(conceptSetSql, vocabulary_database_schema = cdmDatabaseSchema),
    cdm_database_schema = cdmDatabaseSchema,
    snakeCaseToCamelCase = TRUE
  )
  return(counts)
}

jsonToCaprWithReference <- function(json, target) {
  expression <- CirceR::conceptSetExpressionFromJson(json)
  concepts <- c()
  excludedConcepts <- c()
  includeDescendantConcept <- c()
  includeDescendantAndExcludedConcept <- c()
  conceptIds <- c()
  conceptNames <- c()
  for (item in expression$items) {
    conceptId <- item$concept$conceptId$toString()
    conceptName <- item$concept$conceptName
    conceptIds <- c(conceptIds, conceptId)
    conceptNames <- c(conceptNames, conceptName)
    if (item$includeDescendants) {
      if (item$isExcluded) {
        includeDescendantAndExcludedConcept <- c(includeDescendantAndExcludedConcept, conceptId)
      } else {
        includeDescendantConcept <- c(includeDescendantConcept, conceptId)
      } 
    } else {
      if (item$isExcluded) {
        excludedConcepts <- c(excludedConcepts, conceptId)
      } else {
        concepts <- c(concepts, conceptId)
      }
    }
  }
  hasIncludeDescendants <- length(includeDescendantConcept) > 0 || length(includeDescendantAndExcludedConcept) > 0
  code <- paste0("cs(",
                 if (length(concepts) > 0) paste(concepts, collapse = ", ") else "",
                 if (length(concepts) > 0 && hasIncludeDescendants) ", " else "",
                 if (hasIncludeDescendants) "descendants(" else "",
                 if (length(includeDescendantConcept) > 0) paste(includeDescendantConcept, collapse = ", ") else "",
                 if (length(includeDescendantConcept) > 0 && length(includeDescendantAndExcludedConcept) > 0) ", " else "",
                 if (length(includeDescendantAndExcludedConcept) > 0) paste0("exclude(", paste(includeDescendantAndExcludedConcept, collapse = ", "), ")") else "",
                 if (hasIncludeDescendants) ")" else "",
                 if ((length(concepts) > 0 || hasIncludeDescendants) && length(excludedConcepts) > 0) ", " else "",
                 if (length(excludedConcepts) > 0) paste0("exclude(", paste(excludedConcepts, collapse = ", "), ")") else "",
                 ", name = \"", 
                 target, 
                 "\")")
  reference <- lapply(seq_along(conceptIds), 
                      function(i) list(conceptId = as.integer(conceptIds[i]),
                                       conceptName = conceptNames[i]))
  reference <- jsonlite::toJSON(reference,
                                auto_unbox  = TRUE)
  reference <- as.character(reference)
  return(tibble(capr = code, reference = reference))
}

# Tools ----------------------------------------------------------------------------------------------------------------
list_concept_sets <- tool(
  function(phenotype) {
    subset <- conceptSets |>
      filter(normPhenotype == normalizeName(phenotype)) |>
      bind_rows(standardConceptSets) |>
      select(conceptSetName = "target",
             overallPersons) |>
      arrange(conceptSetName)
    
    table <- c("| conceptsetName | personCount |",
               "| -------------- | ----------- |",
               sprintf("| %s | %d |",
                       subset$conceptSetName,
                       subset$overallPersons))
    table <- paste0(table, collapse = "\n")
    return(table)
  },
  name = "list_concept_sets",
  description = paste(
    "Retrieve the concept sets associated with a phenotype.",
    "Returns a markdown table with two columns: concept set name, and the number of unique persons",
    "with at least one of the concepts in the set.",
    "A count of 0 means nobody has any of the concepts."
  ),
  arguments = list(
    phenotype = type_string("Name of the phenotype for which concept sets should be returned.")
  )
)

get_concept_sets_capr <- tool(
  function(phenotype, conceptSetNames, detail = "code_and_counts") {
    if (!detail %in% c("code", "code_and_counts", "full_reference")) {
      stop("The detail argument should be 'code', 'code_and_counts', or 'full_reference'")
    }
    caprWithReference <- conceptSets |>
      filter(normPhenotype == normalizeName(phenotype)) |>
      bind_rows(standardConceptSets) |>
      filter(target %in% conceptSetNames)
    
    # Only allowing 1 definition per concept set:
    caprWithReference <- caprWithReference |>
      group_by(target) |>
      filter(row_number() == 1) |> 
      ungroup() 
    
    # Ensure same order as input:
    caprWithReference <- caprWithReference |>
      inner_join(tibble(target = conceptSetNames,
                        order = seq_along(conceptSetNames)), by = join_by(target)) |>
      arrange(order) |>
      select(-order)
    
    columnsToInclude <- c("capr")
    if (detail %in% c("code_and_counts", "full_reference")) {
      columnsToInclude <- c(columnsToInclude, "conditionPersons", "procedurePersons", "drugPersons", "measurementPersons", "observationPersons", "visitPersons")    }
    if (detail == "full_reference") {
      columnsToInclude <- c(columnsToInclude, "conceptReference")
      caprWithReference <- caprWithReference |>
        mutate(conceptReference = paste("dummy", row_number()))
    }
    result <- caprWithReference[, columnsToInclude]
    json <- jsonlite::toJSON(result, auto_unbox = TRUE, pretty = TRUE)
    
    # Remove 0 counts:
    json <- gsub(",\n  }", "\n  }", gsub('\n[^:]+Persons": 0,?', "", json))
    
    if (detail == "full_reference") {
      for (i in seq_len(nrow(caprWithReference))) {
        json <- gsub(sprintf('"dummy %s"', i), caprWithReference$reference[i], json)
      }
    }
    return(json)
  },
  name = "get_concept_sets_capr",
  description = paste("Returns the Capr R code for one or more concept sets, and unique person counts per domain",
                      "(only non-zero domains)."),
  arguments = list(
    phenotype = type_string("Name of the phenotype."),
    conceptSetNames = type_array(type_string("Names of the concept sets.")),
    detail = type_enum(c("code", "code_and_counts", "full_reference"), 
                       paste("Level of detail to return.",
                             "'code' returns the Capr code,",
                             "'code_and_counts' additionally returns person count per domain, and",
                             "'full_reference' also includes a reference for the concept IDs used in the code.")
    )
  )
)

validate_capr <- tool(
  function(caprCode) {
    result <- tryCatch({
      compileCaprViaWorker(caprCode)
      "Valid"
    },
    error = function(e) {
      return(paste("Error:", e$parent$message))
    }
    )
    return(result)
  },
  name = "validate_capr",
  description = "Validate the provided Capr code. Either returns 'Valid' or an informative error message.",
  arguments = list(
    caprCode = type_string(paste(
      "A single Capr cohort definition as R code: one cohort(...) expression with all concept",
      "sets inlined and no assignments. Compiled server-side — do not pass JSON."
    ))
  )
)

convert_capr_to_json <- tool(
  function(caprCode) {
    json <- compileCaprViaWorker(caprCode)
    
    # Add concept information:
    connection <- DatabaseConnector::connect(connectionDetails)
    on.exit(DatabaseConnector::disconnect(connection))
    
    conceptIds <- stringr::str_match_all(json, '"CONCEPT_ID"\\s*:\\s*(\\d+)')[[1]][, 2] 
    conceptIds <- unique(as.integer(conceptIds))
    sql <- "
      SELECT *
      FROM @cdm_database_schema.concept
      WHERE concept_id IN (@concept_ids);
    "
    concepts <- DatabaseConnector::renderTranslateQuerySql(
      connection = connection,
      sql = sql,
      cdm_database_schema = cdmDatabaseSchema,
      concept_ids = conceptIds
    )
    colnames(concepts) <- toupper(colnames(concepts))
    # Required by ATLAS:
    concepts <- concepts |>
      mutate(STANDARD_CONCEPT_CAPTION = if_else(STANDARD_CONCEPT == "S", 
                                                "Standard", 
                                                if_else(STANDARD_CONCEPT == "C", 
                                                        "Classification",
                                                        "Non-Standard")))
    # concept = split(concepts, concepts$CONCEPT_ID)[[1]]
    for (concept in split(concepts, concepts$CONCEPT_ID)) {
      conceptJson <- jsonlite::toJSON(concept)
      conceptJson <- gsub('\\]$', '', gsub('^\\[', '"concept": ', conceptJson))
      json <-gsub(paste0('"concept":\\s*\\{[^}]*"CONCEPT_ID"\\s*:\\s*',concept$CONCEPT_ID,'[^}]*\\}'),
                  conceptJson,
                  json)
    }
    
    return(json)
  },
  name = "convert_capr_to_json",
  description = paste("Convert Capr code to JSON, including full concept information.",
                      "(This can be a lot of text)."),
  arguments = list(
    caprCode = type_string(paste(
      "A single Capr cohort definition as R code: one cohort(...) expression with all concept",
      "sets inlined and no assignments. Compiled server-side — do not pass JSON."
    ))
  )
)

generate_cohort <- tool(
  function(caprCode) {
    json <- compileCaprViaWorker(caprCode)
    
    connection <- DatabaseConnector::connect(connectionDetails)
    on.exit(DatabaseConnector::disconnect(connection))   
    
    cohortId <- ensureCohortExists(json, connection)
    return(cohortId)
  },
  name = "generate_cohort",
  description = "Generate the cohort in the available database(s) and return the cohort ID.",
  arguments = list(
    caprCode = type_string(paste(
      "A single Capr cohort definition as R code: one cohort(...) expression with all concept",
      "sets inlined and no assignments. Compiled server-side — do not pass JSON."
    ))
  )
)

get_cohort_count <- tool(
  function(cohortId) {
    connection <- DatabaseConnector::connect(connectionDetails)
    on.exit(DatabaseConnector::disconnect(connection))
    
    sql <- "
        SELECT * 
        FROM @cohort_database_schema.@table 
        WHERE cohort_definition_id = @cohort_id;
      "
    inclusionRules <- DatabaseConnector::renderTranslateQuerySql(
      connection = connection,
      sql = sql,
      cohort_database_schema = cohortDatabaseSchema,
      table = CohortGenerator::getCohortTableNames(cohortTable)$cohortInclusionTable,
      cohort_id = cohortId,
      snakeCaseToCamelCase = TRUE
    ) 
    
    if (nrow(inclusionRules) > 0) {
      sql <- "
        SELECT * 
        FROM @cohort_database_schema.@table 
        WHERE cohort_definition_id = @cohort_id;
      "
      inclusionResults <- DatabaseConnector::renderTranslateQuerySql(
        connection = connection,
        sql = sql,
        cohort_database_schema = cohortDatabaseSchema,
        table = getCohortTableNames(cohortTable)$cohortInclusionResultTable,
        cohort_id = cohortId,
        snakeCaseToCamelCase = TRUE
      )
      
      inclusionRules <- bind_rows(inclusionRules, 
                                  tibble(cohortDefinitionId = cohortId, 
                                         ruleSequence = -1,
                                         name = "Initial event"))
      counts <- CohortGenerator::computeCohortAttrition(inclusionResults, inclusionRules) |>
        filter(modeId == 0, cohortEntry == 0) |>
        right_join(inclusionRules, by = join_by(cohortDefinitionId, ruleSequence)) |>
        mutate(ruleSequence  = ruleSequence + 1) |>
        select(ruleSequence, name, personCount) |>
        mutate(personCount = if_else(is.na(personCount), 0, personCount)) |>
        arrange(ruleSequence)
    } else {
      sql <- "
        SELECT COUNT(DISTINCT subject_id) AS person_count, 
          COUNT(*) AS entry_count 
        FROM @cohort_database_schema.@cohort_table 
        WHERE cohort_definition_id = @cohort_id;
      "    
      counts <- DatabaseConnector::renderTranslateQuerySql(
        connection = connection,
        sql = sql,
        cohort_database_schema = cohortDatabaseSchema,
        cohort_table = cohortTable,
        cohort_id = cohortId,
        snakeCaseToCamelCase = TRUE
      )
    }
    counts <- counts |>
      mutate(database = databaseName)
    json <- jsonlite::toJSON(counts)
    return(json)
  },
  name = "get_cohort_count",
  description = paste("Return cohort sizes.",
                      "If the cohort has attrition rules, counts after applying each rule will be returned as well."),
  arguments = list(
    cohortId = type_integer("The cohort ID as returned by the `generate_cohort` tool.")
  )
)

get_database_description <- tool(
  function(databaseName) {
    return(databaseDescription)
  },
  name = "get_database_description",
  description = "Returns a short description of a database.",
  arguments = list(
    databaseName = type_string("Name of the database.")
  )
)

evaluate_cohort <- tool(
  function(cohortId, phenotype) {
    connection <- DatabaseConnector::connect(connectionDetails)
    on.exit(DatabaseConnector::disconnect(connection))
    
    metrics <- Keeper::computeCohortOperatingCharacteristics(
      connection = connection,     
      cohortDatabaseSchema = cohortDatabaseSchema,
      cohortTable = cohortTable,
      cohortDefinitionId = cohortId,
      referenceCohortDatabaseSchema = referenceCohortDatabaseSchema,
      referenceCohortTableNames = createReferenceCohortTableNames(referenceCohortTable),
      referenceCohortDefinitionId = 1
    )
    metrics <- metrics |>
      select("sensitivity",
             specificity = "specificityOverall",
             "ppv",
             "tp",
             "fp",
             "tn",
             "fn")
    json <- jsonlite::toJSON(metrics, pretty = TRUE)
    return(json)
  },
  name = "evaluate_cohort",
  description = paste(
    "Evaluate the cohort using a 10,000 person KEEPER reference cohort.",
    "Returns sensitivity, specificity (adjusted for sampling), PPV, and the confusion matrix."
  ),
  arguments = list(
    cohortId = type_integer("The cohort ID as returned by the `generate_cohort` tool."),
    phenotype = type_string("Name of the phenotype.")
  )
)

sample_patient_profile <- tool(
  function(cohortId, phenotype, type) {
    type <- tolower(type)
    if (!type %in% c("tp", "fp", "tn", "fn")) {
      return("Error: type must have value 'TP', 'FP', 'TN', or 'FN'")
    }
    
    connection <- DatabaseConnector::connect(connectionDetails)
    on.exit(DatabaseConnector::disconnect(connection))
    
    sql <- "
      SELECT CAST(subject_id AS VARCHAR) AS subject_id
      FROM (
        SELECT subject_id,
          is_case,
          MAX(has_match) AS has_match,
          MAX(within_window) as within_window
        FROM (
          SELECT reference_cohort.subject_id,
            is_case,
            CASE WHEN cohort.subject_id IS NULL THEN 0 ELSE 1 END AS has_match,
            CASE 
              WHEN DATEDIFF(DAY, reference_cohort.cohort_start_date, cohort.cohort_start_date) <= 30
                AND DATEDIFF(DAY, reference_cohort.cohort_start_date, cohort.cohort_start_date) >= -30
              THEN 1 
              ELSE 0
            END AS within_window
          FROM @reference_cohort_database_schema.@reference_cohort_table reference_cohort
          LEFT JOIN @cohort_database_schema.@cohort_table cohort
            ON reference_cohort.subject_id = cohort.subject_id
              AND cohort.cohort_definition_id = @cohort_definition_id
              AND cohort.cohort_start_date >= observation_period_start_date
              AND cohort.cohort_start_date <= observation_period_end_date
          WHERE reference_cohort.cohort_definition_id = @reference_cohort_definition_id
            AND reference_cohort.cohort_start_date IS NOT NULL
        ) tmp
        GROUP BY subject_id,
        is_case
      ) tmp2
      {@type == 'tp'} ? {WHERE is_case = 1 AND has_match = 1 AND within_window = 1;}
      {@type == 'tn'} ? {WHERE is_case = 0 AND has_match = 0;}
      {@type == 'fp'} ? {WHERE is_case = 0 AND has_match = 1 AND within_window = 1;}
      {@type == 'fn'} ? {WHERE is_case = 1 AND has_match = 0;}
    "
    personIds <- DatabaseConnector::renderTranslateQuerySql(
      connection = connection,
      sql = sql,
      reference_cohort_database_schema = referenceCohortDatabaseSchema,
      reference_cohort_table = referenceCohortTable,
      reference_cohort_definition_id = 1,
      cohort_database_schema = cohortDatabaseSchema,
      cohort_table = cohortTable,
      cohort_definition_id = cohortId,
      type = type,
      snakeCaseToCamelCase = TRUE,
    )
    if (nrow(personIds) == 0) {
      return(sprintf("No patients of type '%s' found", toupper(type)))
    }
    personId <- sample(personIds$subjectId, size = 1)
    
    sql <- "
      SELECT *
      FROM @reference_cohort_database_schema.@reference_cohort_profiles_table
      WHERE person_id = @person_id
        AND cohort_definition_id = @reference_cohort_definition_id;
    "
    profile <- DatabaseConnector::renderTranslateQuerySql(
      connection = connection,
      sql = sql,
      reference_cohort_database_schema = referenceCohortDatabaseSchema,
      reference_cohort_profiles_table = referenceCohortProfilesTable,
      reference_cohort_definition_id = 1,
      person_id = personId,
      snakeCaseToCamelCase = TRUE,
    )
    result <- list(
      type = toupper(type),
      patientProfile = profile$profile,
      rationale = profile$rationale
    )
    json <- jsonlite::toJSON(result, auto_unbox = TRUE, pretty = TRUE)
    return(json)
  },
  name = "sample_patient_profile",
  description = paste(
    "Return the patient profile and rationale for one random patient in the KEEPER reference set.",
    "Call multiple times to sample multiple patients."
  ),
  arguments = list(
    cohortId = type_integer("The cohort ID as returned by the `generate_cohort` tool."),
    phenotype = type_string("Name of the phenotype. Used to fetch the gold standard."),
    type = type_enum(c("TP", "FP", "TN", "FN"), paste(
      "Type, based on classification status, using the KEEPER reference cohort as gold standard.",
      "Options: TP, FP, TN, FN"
    ))
  )
)

create_new_concept_set <- tool(
  function(name, description) {
    outputFolder <- file.path(newConceptSetsFolder, gsub("[^[:alnum:]]", "", name))
    results <- Phenelope::createConceptSet(
      conceptName = name,
      additionalInformation = description,
      connectionDetails = connectionDetails,
      cdmDatabaseSchema = cdmDatabaseSchema,
      llmClientReasoning = llmClientO3,
      llmClientNonReasoning = llmClient4o,
      outputDirectory = outputFolder
    )
    json <- as.character(jsonlite::toJSON(results$conceptSet, auto_unbox = TRUE))
    sql <- CirceR::buildConceptSetQuery(json)
    counts <- getCounts(sql)
    capr <- jsonToCaprWithReference(json, name)
    result <- bind_cols(
      capr |>
        select(capr),
      counts
    )
    saveRDS(result, file.path(outputFolder, "mcpResult.rds"))
    resultJson <- jsonlite::toJSON(result, auto_unbox = TRUE, pretty = TRUE)
    
    # Remove 0 counts:
    resultJson <- gsub(",\n  }", "\n  }", gsub('\n[^:]+Persons": 0,?', "", resultJson))
    
    return(resultJson)
  },
  name = "create_new_concept_set",
  description = paste("Creates a new concept set given the name and description.",
                      "Returns the Capr R code and unique person counts per domain",
                      "(only non-zero domains)."),
  arguments = list(
    name = type_string("Name of the concept set."),
    description = type_string("Description of the concept set.")
  )
)


# Start the MCP server -------------------------------------------------------------------------------------------------
# This will block the R session and listen for requests from Copilot/Claude.
mcp_server(
  tools = list(
    list_concept_sets,
    get_concept_sets_capr,
    get_cohort_count,
    get_database_description,
    validate_capr,
    convert_capr_to_json,
    generate_cohort,
    evaluate_cohort,
    sample_patient_profile,
    create_new_concept_set
  ),
  session_tools = FALSE
)
