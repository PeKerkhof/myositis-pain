# =============================================================================
# MYOSITIS PAIN CLASSIFICATION: GPT-5.1 WITH EVALUATION
# =============================================================================
#
# PURPOSE:
#   Classify Reddit posts to determine whether the author is referring to their
#   OWN diagnosis (or suspected diagnosis) of inflammatory/autoimmune myositis.
#   This script uses hand-coded ground truth data to evaluate model performance.
#
# WORKFLOW:
#   1. Load hand-coded evaluation dataset with ground truth labels
#   2. Run GPT-5.1 classification multiple times (default: 5 runs)
#   3. Calculate majority vote across runs for stability
#   4. Compute evaluation metrics (Accuracy, F1, Precision, Recall)
#   5. Save predictions and metrics with timestamps
#
# INPUT:
#   - Hand-coded CSV with columns: subreddit, ground_truth, text
#   - Ground truth values: "Yes" (author has myositis) or "No"
#
# OUTPUT:
#   - results_<model>_<timestamp>.csv: Predictions for each run + majority vote
#   - metrics_<model>_<timestamp>.csv: Evaluation metrics per run
#
# =============================================================================


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
library(caret)        # Confusion matrix and metrics
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
batch_size <- 30      # Posts per API call (balance speed vs. token limits)
max_retries <- 3      # Retry attempts for failed API calls


# =============================================================================
# 4. LOAD EVALUATION DATA
# =============================================================================

# Load hand-coded dataset with ground truth labels
file_path <- file.path(DATA_PATH, "LLM output", "pain_posts_llm_handcoded_corrected.csv")

df <- readr::read_csv(file_path, show_col_types = FALSE) |>
  select(subreddit, final, text) |>
  rename(ground_truth = final) |>
  filter(!is.na(text) & trimws(text) != "")

cat("Loaded", nrow(df), "posts for evaluation\n")
cat("Ground truth distribution:\n")
print(table(df$ground_truth))


# =============================================================================
# 5. DEFINE CLASSIFICATION PROMPT
# =============================================================================

# System prompt instructs GPT how to classify posts
# Key criteria:
#   - YES: Author refers to their OWN myositis diagnosis/suspicion
#   - NO:  Reference is to someone else, general/abstract, or symptoms-only

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

Post: {post_content}
Subreddit: {subreddit_name}"


# =============================================================================
# 6. API CALL FUNCTION
# =============================================================================

#' Make a single API call to OpenAI GPT
#'
#' @param prompt The prompt to send to the model
#' @param model Model name (default: model_name from config)
#' @return Character string with model response
#' @note Uses the OpenAI Responses API endpoint

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
#' @return Data frame with 'pred' column added

batch_classify <- function(df, system_prompt, batch_size = 30, retries = 3) {

  # Split data into batches

batches <- split(df, ceiling(seq_len(nrow(df)) / batch_size))

  results <- pbapply::pblapply(batches, function(batch) {

    # Construct batch prompt: system prompt + numbered posts
    batch_prompt <- paste0(
      system_prompt, "\n\n",
      "Classify each of the following Reddit posts as 'Yes' or 'No'. ",
      "Return ONLY a JSON array of strings.\n\n",
      paste0(seq_len(nrow(batch)), ". ", batch$text, collapse = "\n\n")
    )

    # API call with retry logic
    resp_text <- NULL
    for (i in seq_len(retries)) {
      resp_text <- tryCatch(
        gpt_call(batch_prompt),
        error = function(e) {
          message("API error on attempt ", i, ": ", e$message)
          Sys.sleep(2^i)  # Exponential backoff
          NULL
        }
      )
      if (!is.null(resp_text)) break
    }

    # Handle complete failure
    if (is.null(resp_text)) {
      batch$pred <- rep(NA_character_, nrow(batch))
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

    batch$pred <- tools::toTitleCase(tolower(parsed))
    batch
  })

  bind_rows(results)
}


# =============================================================================
# 8. RUN MULTIPLE CLASSIFICATION PASSES
# =============================================================================

# Track timing for each run
model_times <- list()

cat("\n", strrep("=", 60), "\n")
cat("Starting", n_runs, "classification passes with", model_name, "\n")
cat(strrep("=", 60), "\n\n")

for (i in seq_len(n_runs)) {
  message(sprintf("Pass %d/%d...", i, n_runs))
  start <- Sys.time()

  # Run classification
  classified <- batch_classify(df, system_prompt, batch_size = batch_size)

  # Store predictions in named column
  cname <- paste0("pred_", model_label, "_run", i)
  df[[cname]] <- classified$pred
  classified[[cname]] <- classified$pred

  # Record timing
  model_times[[cname]] <- as.numeric(difftime(Sys.time(), start, units = "secs"))
  cat(sprintf("  Completed in %.1f seconds\n", model_times[[cname]]))
}


# =============================================================================
# 9. CALCULATE EVALUATION METRICS
# =============================================================================

cat("\n", strrep("=", 60), "\n")
cat("Computing evaluation metrics\n")
cat(strrep("=", 60), "\n\n")

# Get all prediction column names
prediction_cols <- grep(paste0("^pred_", model_label), names(df), value = TRUE)

# Calculate metrics for each run
metrics_df <- purrr::map_dfr(prediction_cols, function(col) {

  # Create factors with consistent levels
  truth <- factor(df$ground_truth, levels = c("Yes", "No"))
  pred  <- factor(df[[col]], levels = c("Yes", "No"))

  # Compute confusion matrix
  cm <- caret::confusionMatrix(pred, truth, positive = "Yes")

  tibble(
    Model          = col,
    Accuracy       = cm$overall["Accuracy"],
    F1             = cm$byClass["F1"],
    Precision      = cm$byClass["Precision"],
    Recall         = cm$byClass["Recall"],
    TP             = cm$table["Yes", "Yes"],
    FP             = cm$table["Yes", "No"],
    FN             = cm$table["No",  "Yes"],
    TN             = cm$table["No",  "No"],
    Total_Time_Sec = model_times[[col]]
  )
})


# =============================================================================
# 10. CALCULATE MAJORITY VOTE
# =============================================================================

# Majority vote: classify as "Yes" if ≥50% of runs predicted "Yes"
df <- df |>
  mutate(
    yes_votes = rowSums(across(all_of(prediction_cols), \(x) x == "Yes"), na.rm = TRUE),
    majority = if_else(
      yes_votes >= ceiling(length(prediction_cols) / 2),
      "Yes",
      "No"
    )
  )

# Evaluate majority vote performance
cm_final <- confusionMatrix(
  factor(df$majority, levels = c("Yes", "No")),
  factor(df$ground_truth, levels = c("Yes", "No")),
  positive = "Yes"
)

# Add majority vote metrics to results
metrics_df <- bind_rows(
  metrics_df,
  tibble(
    Model          = paste0(model_label, "_MajorityVote"),
    Accuracy       = cm_final$overall["Accuracy"],
    F1             = cm_final$byClass["F1"],
    Precision      = cm_final$byClass["Precision"],
    Recall         = cm_final$byClass["Recall"],
    TP             = cm_final$table["Yes", "Yes"],
    FP             = cm_final$table["Yes", "No"],
    FN             = cm_final$table["No",  "Yes"],
    TN             = cm_final$table["No",  "No"],
    Total_Time_Sec = NA
  )
)


# =============================================================================
# 11. SAVE RESULTS
# =============================================================================

timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

# Save predictions
results_file <- file.path(
  DATA_PATH, "LLM output",
  sprintf("results_%s_%s.csv", model_label, timestamp)
)
#write_csv(df, results_file)

# Save metrics
metrics_file <- file.path(
  DATA_PATH, "LLM output",
  sprintf("metrics_%s_%s.csv", model_label, timestamp)
)
#write_csv(metrics_df, metrics_file)

classified$pred <- NULL
classified$majority <- df$majority

library(caret)
confusionMatrix(factor(classified$ground_truth), factor(classified$majority))
table(manual = classified$ground_truth, LLM = classified$majority)

classified$disagree <- classified$majority != classified$ground_truth




# =============================================================================
# 12. PRINT SUMMARY
# =============================================================================

cat("\n", strrep("=", 60), "\n")
cat("EVALUATION RESULTS\n")
cat(strrep("=", 60), "\n\n")

print(metrics_df)

cat("\n", strrep("-", 60), "\n")
cat("Files saved:\n")
cat("  Predictions:", results_file, "\n")
cat("  Metrics:    ", metrics_file, "\n")
cat(strrep("-", 60), "\n")

cat("\nFinished - Model:", model_name, "(", model_label, ")\n")
