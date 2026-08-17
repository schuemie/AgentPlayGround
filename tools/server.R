# This file runs a local MCP server, providing the functions defined here to the agent. To use, configure your 
# environment to launch the MCP server, for example by adding the following the MCP.json:
# "r-tools": {
#   "command": "Rscript",
#   "args": [
#     "--vanilla",
#     "tools/server.R"
#   ]
# }

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
  sql <- buildCohortQuery(expression, createGenerateOptions(generateStats = FALSE))
  
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
             domains,
             conditionPersons,
             procedurePersons,
             drugPersons,
             measurementPersons,
             observationPersons)

    countCols <- c("conditionPersons", "procedurePersons", "drugPersons",
                   "measurementPersons", "observationPersons")
    domainNames <- c("Condition", "Procedure", "Drug", "Measurement", "Observation")
    countMatrix <- as.matrix(subset[countCols])
    colnames(countMatrix) <- domainNames

    # One record per concept set. `recommendedDomains` flags the domain(s) worth querying:
    # those holding at least 10% of the leading domain's person count, which surfaces concepts
    # recorded across multiple domains (e.g. as both a condition and an observation).
    records <- lapply(seq_len(nrow(subset)), function(i) {
      counts <- countMatrix[i, ]
      counts <- sort(counts[counts > 0], decreasing = TRUE)
      recommended <- if (length(counts)) names(counts)[counts >= 0.1 * max(counts)] else character(0)
      list(
        conceptSetName = subset$conceptSetName[i],
        domainsInVocabulary = subset$domains[i],
        personsByDomain = as.list(counts),
        recommendedDomains = I(recommended)
      )
    })
    jsonlite::toJSON(records, auto_unbox = TRUE, pretty = TRUE)
  },
  description = paste(
    "Retrieve the concept sets associated with a phenotype.",
    "Returns a JSON array with one record per concept set: its name (conceptSetName), the domains",
    "where its concepts exist in the vocabulary (domainsInVocabulary), the number of unique persons",
    "with data in each domain (personsByDomain, only nonzero domains, highest first), and",
    "recommendedDomains \u2014 the domain(s) worth querying (those with at least 10% of the top domain's",
    "person count). Use recommendedDomains to decide whether a concept must be queried in more than",
    "one domain (e.g. as both a condition and an observation)."
  ),
  arguments = list(
    phenotype = type_string("Name of the phenotype for which concept sets should be returned.")
  ),
  name = "list_concept_sets"
)

get_concept_set_capr <- tool(
  function(phenotype, conceptSetName) {
    capr <- conceptSets |>
      filter(normPhenotype == normalizeName(phenotype),
             target == conceptSetName) |>
      pull(capr)
    return(capr)
  },
  description = "Returns the Capr R code for a concept set.",
  arguments = list(
    phenotype = type_string("Name of the phenotype."),
    conceptSetName = type_string("Name of the concept set.")
  ),
  name = "get_concept_set_capr"
)

generate_cohort <- tool(
  function(caprCode) {
    json <- compileCaprViaWorker(caprCode)
    connection <- connect(connectionDetails)
    on.exit(disconnect(connection))
    
    cohortId <- ensureCohortExists(json, connection)
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
    counts <- counts |>
      mutate(database = databaseName)
    return(counts)
  },
  description = paste(
    "Compile a Capr cohort definition (R code) in an isolated, credential-less sandbox and",
    "generate it in the available database(s). Returns cohort sizes."
  ),
  arguments = list(
    caprCode = type_string(paste(
      "A single Capr cohort definition as R code: one cohort(...) expression with all concept",
      "sets inlined and no assignments. Compiled server-side — do not pass JSON."
    ))
  ),
  name = "generate_cohort"
)

get_database_description <- tool(
  function(databaseName) {
    return(databaseDescription)
  },
  description = "Returns a short description of a database.",
  arguments = list(
    databaseName = type_string("Name of the database.")
  ),
  name = "get_database_description"
)

evaluate_cohort <- tool(
  function(caprCode) {
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
    return(metrics)
  },
  description = paste(
    "Compile a Capr cohort definition (R code) in an isolated, credential-less sandbox and",
    "evaluate it using a KEEPER reference cohort. Returns sensitivity, specificity, and PPV."
  ),
  arguments = list(
    caprCode = type_string(paste(
      "A single Capr cohort definition as R code: one cohort(...) expression with all concept",
      "sets inlined and no assignments. Compiled server-side — do not pass JSON."
    ))
  ),
  name = "evaluate_cohort"
)


# Start the MCP server -------------------------------------------------------------------------------------------------
# This will block the R session and listen for requests from Copilot/Claude.
mcp_server(
  tools = list(
    list_concept_sets,
    get_concept_set_capr,
    generate_cohort,
    get_database_description,
    evaluate_cohort
  ),
  session_tools = FALSE
)
