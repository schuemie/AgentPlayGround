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

# Collect all concept sets from folder
connection <- connect(connectionDetails)

folder <- "../largescalephentest/phenelopeConceptSets"

jsonToCapr <- function(json, target) {
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
  comment <- paste0("# Concept set for ", 
                   target, 
                   "\n#\n# Concept ID reference:\n", 
                   paste0("# ", conceptIds, ": ",conceptNames, collapse = "\n"))
  hasIncludeDescendants <- length(includeDescendantConcept) > 0 || length(includeDescendantAndExcludedConcept) > 0
  variableName <- SqlRender::snakeCaseToCamelCase(gsub("[^[:alnum:]]+", "_", target))
  code <- paste0(variableName,
                " <- cs(",
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
  return(paste(comment, code, sep = "\n"))
}

getCounts <- function(conceptSetSql) {
  sql <- "
  WITH concept_set AS (
    @concept_set_sql
  )
  SELECT 
    (
      SELECT COUNT(DISTINCT person_id) 
      FROM @cdm_database_schema.condition_occurrence 
      WHERE condition_concept_id IN (SELECT concept_id FROM concept_set)
    ) AS condition_persons,
    (
      SELECT COUNT(DISTINCT person_id) 
      FROM @cdm_database_schema.procedure_occurrence 
      WHERE procedure_concept_id IN (SELECT concept_id FROM concept_set)
    ) AS procedure_persons,
    (
      SELECT COUNT(DISTINCT person_id)
      FROM @cdm_database_schema.drug_exposure
      WHERE drug_concept_id IN (SELECT concept_id FROM concept_set)
    ) AS drug_persons,
    (
      SELECT COUNT(DISTINCT person_id)
      FROM @cdm_database_schema.measurement
      WHERE measurement_concept_id IN (SELECT concept_id FROM concept_set)
    ) AS measurement_persons,
    (
      SELECT COUNT(DISTINCT person_id)
      FROM @cdm_database_schema.observation
      WHERE observation_concept_id IN (SELECT concept_id FROM concept_set)
    ) AS observation_persons;"
  counts <- renderTranslateQuerySql(connection = connection,
                                    sql = sql,
                                    concept_set_sql = SqlRender::render(conceptSetSql, vocabulary_database_schema = cdmDatabaseSchema),
                                    cdm_database_schema = cdmDatabaseSchema,
                                    snakeCaseToCamelCase = TRUE)
  return(counts)
}

# target = targets[1]
processConceptSetTarget <- function(target, role, phenotype) {
  jsonFile <- file.path(folder, phenotype, role, target, sprintf("%s.json", target))
  if (!file.exists(jsonFile)) {
    # No concepts found
    return(NULL)
  }
  json <- readLines(jsonFile)  
  json <- paste(json, collapse = "\n")
  conceptSetSql <- CirceR::buildConceptSetQuery(json)
  capr <- jsonToCapr(json, target)
  
  domains <- readr::read_csv(file.path(folder, phenotype, role, target, "domains.csv"), show_col_types = FALSE)
  domains <- paste(domains$domainId, collapse = ",")
  
  counts <- getCounts(conceptSetSql)
  
  row <- tibble(
    phenotype = phenotype,
    role = role,
    target = target,
    domains = domains,
    json = json,
    sql = conceptSetSql,
    capr = capr
  ) |> 
    bind_cols(counts)
}

# role = roles[1]
processRole <- function(role, phenotype) {
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

object.size(rows)
saveRDS(rows, "tools/PhenelopeConceptSets.rds")
readr::write_csv(rows, "../largescalephentest/phenelopeConceptSets/overview.csv")
