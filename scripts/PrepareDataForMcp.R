# setwd("E:/git/AgentPlayGround")

library(DatabaseConnector)
library(dplyr)

connectionDetails <- createConnectionDetails(
  dbms = "spark",
  connectionString = keyring::key_get("databricksConnectionString"),
  user = "token",
  password = keyring::key_get("databricksToken")
)
cdmDatabaseSchema <- "optum_extended_dod.cdm_optum_extended_dod_v4020"
options(sqlRenderTempEmulationSchema = "scratch.scratch_mschuemi")

referenceCohortDatabaseSchema <- "scratch.scratch_all"
referenceCohortProfilesTable <- "reference_cohort_profiles_optum_extended_dod_v4020"

# Collect all concept sets from folder ------------------------------------------------------
connection <- connect(connectionDetails)

folder <- "../largescalephentest/phenelopeConceptSets"

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

getCounts <- function(conceptSetSql) {
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
      
      UNION ALL
       
      SELECT DISTINCT
       person_id,
       'Visit' AS domain_id
      FROM @cdm_database_schema.visit_occurrence
      WHERE visit_concept_id IN (
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
       
      COUNT(DISTINCT CASE
        WHEN domain_id = 'Visit' THEN person_id
      END) AS visit_persons,
      
      COUNT(DISTINCT person_id) AS overall_persons
      FROM domain_persons;
  "
  counts <- renderTranslateQuerySql(connection = connection,
                                    sql = sql,
                                    concept_set_sql = SqlRender::render(conceptSetSql, vocabulary_database_schema = cdmDatabaseSchema),
                                    cdm_database_schema = cdmDatabaseSchema,
                                    snakeCaseToCamelCase = TRUE)
  return(counts)
}

# target = targets[2]
processConceptSetTarget <- function(target, role, phenotype) {
  jsonFile <- file.path(folder, phenotype, role, target, sprintf("%s.json", target))
  if (!file.exists(jsonFile)) {
    # No concepts found
    return(NULL)
  }
  json <- readLines(jsonFile)  
  json <- paste(json, collapse = "\n")
  conceptSetSql <- CirceR::buildConceptSetQuery(json)
  caprWithReference <- jsonToCaprWithReference(json, target)
  
  domains <- readr::read_csv(file.path(folder, phenotype, role, target, "domains.csv"), show_col_types = FALSE)
  domains <- paste(domains$domainId, collapse = ",")
  
  counts <- getCounts(conceptSetSql)
  
  row <- tibble(
    phenotype = phenotype,
    role = role,
    target = target,
    domains = domains,
    json = json,
    sql = conceptSetSql
  ) |> 
    bind_cols(caprWithReference) |>
    bind_cols(counts)
}

# role = roles[1]
processRole <- function(role, phenotype) {
  message(sprintf("- Processing %s - %s", phenotype, role))
  targets <- list.files(file.path(folder, phenotype, role))
  rows <- lapply(targets, processConceptSetTarget, role = role, phenotype = phenotype)
  rows <- bind_rows(rows)
  return(rows)
}

# phenotype = phenotypes[1]
processPhenotype <- function(phenotype) {
  roles <- list.dirs(file.path(folder, phenotype), recursive = FALSE, full.names = FALSE)
  rows <- lapply(roles, processRole, phenotype = phenotype)
  rows <- bind_rows(rows)
}

phenotypes <- list.dirs(folder, recursive = FALSE, full.names = FALSE)
rows <- lapply(phenotypes, processPhenotype)
rows <- bind_rows(rows)

object.size(rows) / 1024^2
saveRDS(rows, "tools/PhenelopeConceptSets.rds")
readr::write_csv(rows, file.path(folder, "overview.csv"))
disconnect(connection)

# Add standard concept sets ---------------------------------------------------------------
connection <- connect(connectionDetails)

# conceptSet = standardConceptSets[[1]]
processStandardConceptSet <- function(conceptSet) {
  conceptSet <- Capr::getConceptSetDetails(conceptSet, connection, cdmDatabaseSchema)
  json <- Capr::toConceptSetJson(conceptSet)
  target <- conceptSet@Name
  conceptSetSql <- CirceR::buildConceptSetQuery(json)
  caprWithReference <- jsonToCaprWithReference(json, target)

  counts <- getCounts(conceptSetSql)
  
  row <- tibble(
    target = target,
    json = json,
    sql = conceptSetSql
  ) |> 
    bind_cols(caprWithReference) |>
    bind_cols(counts)
  return(row)
}

standardConceptSets <- list(
  Capr::cs(Capr::descendants(9201), name = "Inpatient visit"),
  Capr::cs(Capr::descendants(9202), name = "Outpatient visit"),
  Capr::cs(Capr::descendants(9203, 262), name = "Emergency room visit")
)
rows <- lapply(standardConceptSets, processStandardConceptSet)
rows <- bind_rows(rows)
saveRDS(rows, "tools/StandardConceptSets.rds")

disconnect(connection)

# Upload KEEPER profiles ------------------------------------------------------------------
folder <- "../largescalephentest/AcuteLiverFailure"
keeperProfiles <- readRDS(file.path(folder, "KeeperHsc.rds"))
llmReviews <- readRDS(file.path(folder, "llmReviewsHsc.rds"))

# group = groups[[1]]
createRow <- function(group) {
  llmReview <- llmReviews |>
    filter(generatedId == group$generatedId[1])
  profileText <- Keeper:::createPrompt(Keeper::createPromptSettings(), group)
  row <- llmReview |>
    select("personId", "isCase", rationale = "justification") |>
    mutate(profile = profileText)
  return(row)
}
groups <- keeperProfiles |>
  group_by(generatedId) |>
  group_split()

rows <- lapply(groups, createRow)
rows <- bind_rows(rows)
rows$cohortDefinitionId <- 1 # TODO: connect this with reference table

connection <- connect(connectionDetails)

rows$personId <- bit64::as.integer64(rows$personId)
insertTable(
  connection = connection,
  databaseSchema = referenceCohortDatabaseSchema,
  tableName = referenceCohortProfilesTable,
  data = rows,
  dropTableIfExists = TRUE,
  createTable = TRUE,
  progressBar = TRUE,
  camelCaseToSnakeCase = TRUE
)

disconnect(connection)
