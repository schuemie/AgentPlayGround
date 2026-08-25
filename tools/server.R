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


# setwd("E:/git/AgentPlayGround")

library(mcptools)
library(ellmer)
library(dplyr)
library(CirceR)
library(DatabaseConnector)
library(Keeper)
library(CohortGenerator)

connectionDetails <- createConnectionDetails(
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


# Support functions and global variables -------------------------------------------------------------------------------
normalizeName <- function(name) {
  return(gsub("[^[:alnum:]]", "", tolower(name)))
}

conceptSets <- readRDS("tools/PhenelopeConceptSets.rds") |>
  mutate(normPhenotype = normalizeName(phenotype))

# Returns the cohort ID:
ensureCohortExists <- function(json, connection) {
  expression <- cohortExpressionFromJson(json)
  sql <- buildCohortQuery(expression, createGenerateOptions(generateStats = TRUE))
  
  cohortTableNames <- getCohortTableNames(cohortTable)
  if (existsTable(connection, cohortDatabaseSchema, cohortTable)) {
    existingCohorts <- renderTranslateQuerySql(
      connection = connection,
      sql = "SELECT cohort_definition_id, checksum FROM @cohort_database_schema.@table;",
      cohort_database_schema = cohortDatabaseSchema,
      table = cohortTableNames$cohortChecksumTable,
      snakeCaseToCamelCase = TRUE
    )
    matchingCohortId <- existingCohorts |>
      filter(checksum ==  computeChecksum(sql)) |>
      pull(cohortDefinitionId)
    
    if (length(matchingCohortId) == 1) {
      return(matchingCohortId)
    } else {
      nextCohortId <- max(existingCohorts$cohortDefinitionId) + 1
    }
  } else {
    createCohortTables(
      connection = connection,
      cohortDatabaseSchema = cohortDatabaseSchema,
      cohortTableNames = cohortTableNames
    )
    nextCohortId <- 1
  }
  cohortDefinitionSet <- tibble(
    cohortId = nextCohortId,
    cohortName = paste("Cohort", nextCohortId),
    sql = sql
  )
  generateCohortSet(
    connection = connection,
    cdmDatabaseSchema = cdmDatabaseSchema,
    cohortDatabaseSchema = cohortDatabaseSchema,
    cohortTableNames = cohortTableNames,
    cohortDefinitionSet = cohortDefinitionSet,
    incremental = TRUE,
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

# Tools ----------------------------------------------------------------------------------------------------------------
list_concept_sets <- tool(
  function(phenotype) {
    subset <- conceptSets |>
      filter(normPhenotype == normalizeName(phenotype)) |>
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
    "with at least one of the concepts in the set."
  ),
  arguments = list(
    phenotype = type_string("Name of the phenotype for which concept sets should be returned.")
  )
)

get_concept_set_capr <- tool(
  function(phenotype, conceptSetName, detail = "code_and_counts") {
    if (!detail %in% c("code", "code_and_counts", "full_reference")) {
      stop("The detail argument should be 'code', 'code_and_counts', or 'full_reference'")
    }
    caprWithReference <- conceptSets |>
      filter(normPhenotype == normalizeName(phenotype),
             target == conceptSetName) |>
      head(1) # Only allowing 1 definition per concept set
    result <- list(
      capr = caprWithReference$capr
    )
    if (detail %in% c("code_and_counts", "full_reference")) {
      if (caprWithReference$conditionPersons > 0) {
        result$conditionPersons = caprWithReference$conditionPersons
      }
      if (caprWithReference$procedurePersons > 0) {
        result$procedurePersons = caprWithReference$procedurePersons
      }
      if (caprWithReference$drugPersons > 0) {
        result$drugPersons = caprWithReference$drugPersons
      }
      if (caprWithReference$measurementPersons > 0) {
        result$measurementPersons = caprWithReference$measurementPersons
      }
      if (caprWithReference$observationPersons > 0) {
        result$observationPersons = caprWithReference$observationPersons
      }
    }
    if (detail == "full_reference") {
      result$conceptReference <- "dummy"
    }
    json <- jsonlite::toJSON(result, auto_unbox = TRUE, pretty = TRUE)
    if (detail == "full_reference") {
      json <- gsub("\"dummy\"", caprWithReference$reference, json)
    }
    return(json)
  },
  name = "get_concept_set_capr",
  description = paste("Returns the Capr R code for a concept set, and unique person counts per domain,",
                      "only non-zero domains."),
  arguments = list(
    phenotype = type_string("Name of the phenotype."),
    conceptSetName = type_string("Name of the concept set."),
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

get_cohort_count <- tool(
  function(caprCode) {
    json <- compileCaprViaWorker(caprCode)
    connection <- connect(connectionDetails)
    on.exit(disconnect(connection))
    
    cohortId <- ensureCohortExists(json, connection)
    
    expression <- jsonlite::fromJSON(json)
    inclusionRules <- expression$InclusionRules
    
    if (nrow(inclusionRules) > 0) {
      inclusionRules <- inclusionRules |> 
        transmute(cohortDefinitionId = cohortId, ruleSequence = row_number() -1, name)
      
      stats <- getCohortStats(
        connection = connection,
        cohortDatabaseSchema = cohortDatabaseSchema,
        outputTables = "cohortInclusionResultTable",
        cohortTableNames = getCohortTableNames(cohortTable)
      )
      inclusionRules <- bind_rows(inclusionRules, 
                                  tibble(cohortDefinitionId = cohortId, 
                                         ruleSequence = -1,
                                         name = "Initial event"))
      counts <- computeCohortAttrition(stats$cohortInclusionResultTable, inclusionRules) |>
        filter(modeId == 0, cohortEntry == 0) |>
        inner_join(inclusionRules, by = join_by(cohortDefinitionId, ruleSequence)) |>
        mutate(ruleSequence  = ruleSequence + 1) |>
        select(ruleSequence, name, personCount)
    } else {
      sql <- "
      SELECT COUNT(DISTINCT subject_id) AS person_count, 
        COUNT(*) AS entry_count 
      FROM @cohort_database_schema.@cohort_table 
      WHERE cohort_definition_id = @cohort_id;
    "    
      counts <- renderTranslateQuerySql(
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
  description = paste("Generate the cohort in the available database(s) (if needed) and return cohort sizes.",
                      "If the cohort has attrition rules, counts after applying each rule will be returned as well."),
  arguments = list(
    caprCode = type_string(paste(
      "A single Capr cohort definition as R code: one cohort(...) expression with all concept",
      "sets inlined and no assignments. Compiled server-side — do not pass JSON."
    ))
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
  function(caprCode, phenotype) {
    json <- compileCaprViaWorker(caprCode)
    connection <- connect(connectionDetails)
    on.exit(disconnect(connection))
    
    cohortId <- ensureCohortExists(json, connection)
    metrics <- computeCohortOperatingCharacteristics(
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
             ppv)
    json <- jsonlite::toJSON(metrics, pretty = TRUE)
    return(json)
  },
  name = "evaluate_cohort",
  description = paste(
    "Generate the cohort in the available database(s) (if needed) and evaluate it using",
    "a 10,000 person KEEPER reference cohort. Returns sensitivity, specificity, and PPV."
  ),
  arguments = list(
    caprCode = type_string(paste(
      "A single Capr cohort definition as R code: one cohort(...) expression with all concept",
      "sets inlined and no assignments. Compiled server-side — do not pass JSON."
    )),
    phenotype = type_string("Name of the phenotype.")
  )
)


sample_patient_profile <- tool(
  function(caprCode, phenotype, type) {
    type <- tolower(type)
    if (!type %in% c("tp", "fp", "tn", "fn")) {
      return("Error: type must have value 'TP', 'FP', 'TN', or 'FN'")
    }
    
    json <- compileCaprViaWorker(caprCode)
    connection <- connect(connectionDetails)
    on.exit(disconnect(connection))
    
    cohortId <- ensureCohortExists(json, connection)
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
    personIds <- renderTranslateQuerySql(
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
    profile <- renderTranslateQuerySql(
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
    "Generate the cohort in the available database(s) (if needed) and return the patient profile",
    "and rationale for one random patient in the KEEPER reference set."
  ),
  arguments = list(
    caprCode = type_string(paste(
      "A single Capr cohort definition as R code: one cohort(...) expression with all concept",
      "sets inlined and no assignments. Compiled server-side — do not pass JSON."
    )),
    phenotype = type_string("Name of the phenotype. Used to fetch the gold standard."),
    type = type_string(paste(
      "Type, based on classification status, using the KEEPER reference cohort as gold standard.",
      "Options: TP, FP, TN, FN"
    ))
  )
)

# Start the MCP server -------------------------------------------------------------------------------------------------
# This will block the R session and listen for requests from Copilot/Claude.
mcp_server(
  tools = list(
    list_concept_sets,
    get_concept_set_capr,
    get_cohort_count,
    get_database_description,
    validate_capr,
    evaluate_cohort,
    sample_patient_profile
  ),
  session_tools = FALSE
)
