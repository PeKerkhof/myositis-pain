# =============================================================================
# MYOSITIS PAIN CLASSIFICATION: GPT-5.1 ON FULL DATASET
# =============================================================================
#
# PURPOSE:
#   Apply the validated GPT-5.1 classification to the FULL cleaned myositis
#   dataset. Identifies posts where authors refer to their OWN myositis
#   diagnosis or suspected diagnosis.
#
# WORKFLOW:
#   PART A - CLASSIFICATION:
#     1. Load full cleaned dataset
#     2. Run GPT-5.1 classification multiple times (5 runs)
#     3. Calculate majority vote across runs for stability
#     4. Save predictions
#
#   PART B - NEAR-DUPLICATE REMOVAL:
#     5. Load classified posts (majority_vote == "Yes")
#     6. Use MinHash/LSH to detect near-duplicate posts
#     7. Cluster duplicates and keep oldest post per cluster
#     8. Save deduplicated dataset
#
# INPUT:
#   - Cleaned feather file: myositis_submissions_2005_july2025_clean.feather
#
# OUTPUT:
#   - full_predictions_<model>_<timestamp>.feather: All posts with predictions
#   - majority_vote_<model>_<timestamp>.feather: Deduplicated "Yes" posts only
#
# =============================================================================


# #############################################################################
#                         PART A: CLASSIFICATION
# #############################################################################


# =============================================================================
# 1. ENVIRONMENT SETUP
# =============================================================================

# Clear environment (preserve functions) and reset console
rm(list = ls()[!sapply(ls(), function(x) is.function(get(x)))])
cat("\014")


# =============================================================================
# 2. LOAD REQUIRED LIBRARIES
# =============================================================================

library(tidyverse)    # Data manipulation
library(pbapply)      # Progress bars for apply functions
library(jsonlite)     # JSON parsing for API responses
library(here)         # Project-relative paths
library(arrow)        # Read/write feather files
library(httr2)        # HTTP requests to OpenAI API

# Load project configuration (DATA_PATH)
source(here("config.R"))


# =============================================================================
# 3. CONFIGURATION
# =============================================================================

# --- API Configuration ---
api_key <- Sys.getenv("OPENAI_API_KEY")
if (api_key == "") stop("Error: OPENAI_API_KEY environment variable is not set.")

# --- Model Configuration ---
model_name  <- "gpt-5.1"
model_label <- gsub("[^A-Za-z0-9]", "", model_name)  # Safe label for filenames

# --- Run Configuration ---
n_runs     <- 5       # Number of classification passes for majority voting
batch_size <- 30      # Posts per API call


# =============================================================================
# 4. LOAD FULL CLEANED DATASET
# =============================================================================

file_path <- file.path(DATA_PATH, "data", "myositis_submissions_2005_july2025_clean.feather")

df <- arrow::read_feather(file_path) |>
  filter(!is.na(text) & trimws(text) != "")

cat("Loaded", scales::comma(nrow(df)), "posts for classification\n")
cat("Date range:", min(df$date), "to", max(df$date), "\n")


# =============================================================================
# 5. DEFINE CLASSIFICATION PROMPT
# =============================================================================

# System prompt: same as used in evaluation script (validated for high accuracy)
# Classifies whether author refers to their OWN myositis diagnosis

system_prompt <- "
You are a domain expert in medical social media analysis.
Your task is to decide whether the author of a Reddit post is referring to *their own* diagnosis or suspected diagnosis of an inflammatory or autoimmune myositis (e.g., dermatomyositis, polymyositis, antisynthetase syndrome, immune-mediated necrotizing myopathy, inclusion body myositis, juvenile dermatomyositis, overlap myositis).

Your output must be ONLY: Yes or No

----------------------------------------------------
CLASSIFY AS 'YES' IF ANY OF THE FOLLOWING ARE TRUE:
----------------------------------------------------
1. The author explicitly states they have, had, or were diagnosed with myositis.
2. The author reports that *they themselves* are being evaluated/tested for myositis.
3. The author shows personal suspicion that they may have myositis.
4. If the Subreddit is r/myositis, r/polymyositis, or r/dermatomyositis, classify as 'Yes' UNLESS it clearly refers to someone else.

----------------------------------------------------
CLASSIFY AS 'NO' IF ANY OF THESE ARE TRUE:
----------------------------------------------------
1. Symptoms only are listed without mention of myositis or testing.
2. Reference is general/abstract (not personal).
3. The diagnosis refers to someone else (family/friend).

Output:
Yes
or
No

Post:
{{text}}

Subreddit:
{{subreddit}}
"


# =============================================================================
# 6. API CALL FUNCTION
# =============================================================================

#' Make a single API call to OpenAI GPT
#'
#' @param prompt The prompt to send to the model
#' @param model Model name (default: model_name from config)
#' @return Character string with model response

gpt_call <- function(prompt, model = model_name) {

  resp <- request("https://api.openai.com/v1/responses") |>
    req_headers(
      Authorization = paste("Bearer", Sys.getenv("OPENAI_API_KEY")),
      "Content-Type" = "application/json"
    ) |>
    req_body_json(list(
      model = model,
      input = prompt
    )) |>
    req_perform()

  out <- resp_body_json(resp)

  # Extract message content from response
  types <- vapply(out$output, function(x) x$type, character(1))
  msg_idx <- which(types == "message")[1]
  if (is.na(msg_idx)) stop("No 'message' output found in API response.")

  out$output[[msg_idx]]$content[[1]]$text
}


# =============================================================================
# 7. BATCH CLASSIFICATION FUNCTION
# =============================================================================

#' Classify posts in batches with retry logic
#'
#' @param df Data frame with 'text' and 'subreddit' columns
#' @param system_prompt The classification prompt template
#' @param batch_size Number of posts per API call
#' @param retries Number of retry attempts on failure
#' @return Data frame with 'prediction' column added

batch_classify <- function(df, system_prompt, batch_size = 30, retries = 3) {

  # Split data into batches
  batches <- split(df, ceiling(seq_len(nrow(df)) / batch_size))

  results <- pbapply::pblapply(batches, function(batch) {

    # Construct batch prompt with subreddit context
    batch_prompt <- paste0(
      system_prompt, "\n\n",
      "Classify each of the following Reddit posts as 'Yes' or 'No'. ",
      "Return ONLY a JSON array of strings.\n\n",
      paste0(
        seq_len(nrow(batch)), ". Subreddit: ", batch$subreddit,
        "\nPost: ", batch$text, collapse = "\n\n"
      )
    )

    # API call with retry logic
    resp_text <- NULL
    for (i in seq_len(retries)) {
      resp_text <- tryCatch(
        gpt_call(batch_prompt),
        error = function(e) {
          message("API error attempt ", i, ": ", e$message)
          Sys.sleep(2^i)  # Exponential backoff
          NULL
        }
      )
      if (!is.null(resp_text)) break
    }

    # Handle complete failure
    if (is.null(resp_text)) {
      batch$prediction <- rep(NA_character_, nrow(batch))
      return(batch)
    }

    # Parse response: remove markdown code blocks if present
    cleaned <- gsub("```[a-zA-Z]*\\s*|```", "", resp_text) |> trimws()

    # Try JSON parsing first, fall back to regex extraction
    parsed <- tryCatch(
      jsonlite::fromJSON(cleaned),
      error = function(e) {
        stringr::str_extract_all(cleaned, "(?i)\\bYes\\b|\\bNo\\b")[[1]]
      }
    )

    # Ensure correct length (pad or truncate as needed)
    if (length(parsed) < nrow(batch)) {
      parsed <- c(parsed, rep(NA_character_, nrow(batch) - length(parsed)))
    } else if (length(parsed) > nrow(batch)) {
      parsed <- parsed[seq_len(nrow(batch))]
    }

    batch$prediction <- tools::toTitleCase(tolower(parsed))
    batch
  })

  bind_rows(results)
}


# =============================================================================
# 8. RUN MULTIPLE CLASSIFICATION PASSES
# =============================================================================

cat("\n", strrep("=", 60), "\n")
cat("Starting", n_runs, "classification passes with", model_name, "\n")
cat("Total posts:", scales::comma(nrow(df)), "\n")
cat(strrep("=", 60), "\n\n")

for (i in seq_len(n_runs)) {
  message(sprintf("Pass %d/%d...", i, n_runs))
  start <- Sys.time()

  classified <- batch_classify(df, system_prompt, batch_size = batch_size)

  cname <- paste0("pred_", model_label, "_run", i)
  df[[cname]] <- classified$prediction

  elapsed <- as.numeric(difftime(Sys.time(), start, units = "mins"))
  cat(sprintf("  Completed in %.1f minutes\n", elapsed))
}


# =============================================================================
# 9. CALCULATE MAJORITY VOTE
# =============================================================================

# Get all prediction column names
prediction_cols <- grep(paste0("^pred_", model_label), names(df), value = TRUE)

# Majority vote: classify as "Yes" if ≥50% of runs predicted "Yes"
df <- df |>
  mutate(
    yes_votes = rowSums(across(all_of(prediction_cols), \(x) x == "Yes"), na.rm = TRUE),
    majority_vote = if_else(
      yes_votes >= ceiling(n_runs / 2),
      "Yes", "No"
    )
  )

cat("\nMajority vote distribution:\n")
print(table(df$majority_vote))


# =============================================================================
# 10. SAVE CLASSIFICATION RESULTS
# =============================================================================

timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

outfile <- file.path(
  DATA_PATH, "LLM output",
  sprintf("full_predictions_%s_%s.feather", model_label, timestamp)
)

arrow::write_feather(df, outfile)

cat("\nClassification complete.\n")
cat("Saved to:", outfile, "\n")


# #############################################################################
#                    PART B: NEAR-DUPLICATE REMOVAL
# #############################################################################

# =============================================================================
# 11. LOAD LIBRARIES FOR DEDUPLICATION
# =============================================================================

library(textreuse)    # MinHash and LSH for near-duplicate detection
library(igraph)       # Graph-based clustering of duplicates


# =============================================================================
# 12. LOAD CLASSIFIED DATA (OR USE FROM MEMORY)
# =============================================================================

# Option 1: Continue with df from Part A
# Option 2: Load from saved file (uncomment if running separately)
# df <- arrow::read_feather(file.path(DATA_PATH, "LLM output", "full_predictions_gpt51_YYYYMMDD_HHMMSS.feather"))

# Filter to "Yes" posts only and prepare for deduplication
df_yes <- df |>
  filter(majority_vote == "Yes") |>
  arrange(desc(created_utc))

cat("\n", strrep("=", 60), "\n")
cat("NEAR-DUPLICATE REMOVAL\n")
cat(strrep("=", 60), "\n")
cat("Posts with majority_vote='Yes':", scales::comma(nrow(df_yes)), "\n")


# =============================================================================
# 13. PREPARE DATA FOR MINHASH/LSH
# =============================================================================

# Filter to posts with non-empty selftext
df2 <- df_yes |>
  filter(!is.na(selftext), trimws(selftext) != "") |>
  mutate(doc_id = as.character(doc_id))

cat("Posts with non-empty selftext:", scales::comma(nrow(df2)), "\n")

# Create named character vector for textreuse
docs <- setNames(df2$selftext, df2$doc_id)


# =============================================================================
# 14. BUILD MINHASH CORPUS
# =============================================================================

# MinHash parameters:
#   - n = 200: Number of hash functions (higher = more accurate, slower)
#   - 5-gram tokenization: Compare overlapping 5-word sequences

set.seed(1)  # For reproducibility
mh_fun <- minhash_generator(n = 200)

corpus <- TextReuseCorpus(
  text         = docs,
  tokenizer    = tokenize_ngrams,
  n            = 5,              # 5-gram tokenization
  lowercase    = TRUE,
  keep_tokens  = FALSE,          # Save memory
  minhash_func = mh_fun
)


# =============================================================================
# 15. LSH CANDIDATE DETECTION AND COMPARISON
# =============================================================================

# LSH parameters:
#   - bands = 50: More bands = catches looser matches (approx 37%+ similarity)
#   - We filter strictly later at our chosen threshold

buckets <- lsh(corpus, bands = 50)
cands   <- lsh_candidates(buckets)
pairs   <- lsh_compare(cands, corpus, jaccard_similarity)

cat("Candidate pairs found:", scales::comma(nrow(pairs)), "\n")


# =============================================================================
# 16. FILTER FOR STRICT SIMILARITY THRESHOLD
# =============================================================================

# Similarity threshold: 0.10 (set after visual inspection)
# Lower threshold catches more potential duplicates for manual review
similarity_threshold <- 0.10

pairs2 <- pairs |>
  filter(score >= similarity_threshold)

cat("Pairs above threshold (", similarity_threshold, "):", scales::comma(nrow(pairs2)), "\n")


# =============================================================================
# 17. GRAPH-BASED DEDUPLICATION
# =============================================================================

# Build graph where edges connect near-duplicate posts
g <- graph_from_data_frame(
  pairs2 |> transmute(from = as.character(a), to = as.character(b)),
  directed = FALSE
)

# Find connected components (clusters of duplicates)
memb <- components(g)$membership

# Tag posts with cluster membership
# Posts not in graph are unique ("solo") posts
df_keep <- df2 |>
  mutate(cluster = if_else(
    doc_id %in% names(memb),
    paste0("cl_", memb[doc_id]),
    paste0("solo_", doc_id)
  )) |>
  # Keep only the oldest post per cluster
  group_by(cluster) |>
  arrange(created_utc, .by_group = TRUE) |>
  slice(1) |>
  ungroup()


# =============================================================================
# 18. BUILD DEDUPLICATION OVERVIEW (FOR INSPECTION)
# =============================================================================

# Detailed view of duplicate pairs for quality checking
cols_needed <- c("doc_id", "author", "created_utc", "selftext", "subreddit")

overview <- pairs2 |>
  arrange(desc(score)) |>

  # Join document A details
  left_join(df2 |> select(all_of(cols_needed)), by = c("a" = "doc_id")) |>
  rename(
    author_a      = author,
    created_utc_a = created_utc,
    text_a        = selftext,
    subreddit_a   = subreddit
  ) |>

  # Join document B details
  left_join(df2 |> select(all_of(cols_needed)), by = c("b" = "doc_id")) |>
  rename(
    author_b      = author,
    created_utc_b = created_utc,
    text_b        = selftext,
    subreddit_b   = subreddit
  ) |>

  # Calculate time difference between posts
  mutate(
    diff_seconds = as.numeric(created_utc_a) - as.numeric(created_utc_b),
    diff_hours   = diff_seconds / 3600
  ) |>

  # Final column selection
  select(
    similarity_score = score,
    created_utc_a, created_utc_b,
    subreddit_a, subreddit_b,
    author_a, author_b,
    diff_hours,
    text_a, text_b
  )


# =============================================================================
# 19. PRINT DEDUPLICATION SUMMARY
# =============================================================================

cat("\n", strrep("-", 60), "\n")
cat("DEDUPLICATION RESULTS\n")
cat(strrep("-", 60), "\n")
cat("Original posts (majority_vote='Yes'):", scales::comma(nrow(df2)), "\n")
cat("After deduplication:                 ", scales::comma(nrow(df_keep)), "\n")
cat("Duplicates removed:                  ", scales::comma(nrow(df2) - nrow(df_keep)), "\n")
cat(strrep("-", 60), "\n")


# =============================================================================
# 20. SAVE DEDUPLICATED DATA
# =============================================================================

# Note: Update timestamp to match classification output for traceability
dedup_outfile <- file.path(
  DATA_PATH, "LLM output",
  sprintf("majority_vote_%s_%s.feather", model_label, timestamp)
)

#arrow::write_feather(df_keep, dedup_outfile)

cat("\nDeduplicated data saved to:", dedup_outfile, "\n")
cat("\nPipeline complete.\n")
