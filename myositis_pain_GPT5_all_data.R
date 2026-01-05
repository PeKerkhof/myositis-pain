#### Clean environment ####
rm(list = ls()[!sapply(ls(), function(x) is.function(get(x)))])
cat("\014")

#### Load Required Libraries ####
library(tidyverse)
library(pbapply)
library(jsonlite)
library(here)
library(arrow)

#### Load API Key ####
api_key <- Sys.getenv("OPENAI_API_KEY")
if (api_key == "") stop("Error: OPENAI_API_KEY is not set.")

#### Load FULL DATASET ####
# Adjust file path as needed:
file_path <- here("data", "myositis_submissions_2005_july2025_clean.feather")

df <- arrow::read_feather(file_path) |>
  filter(!is.na(text) & trimws(text) != "")

#### Define GPT model ####
model_name <- "gpt-5.1"
model_label <- gsub("[^A-Za-z0-9]", "", model_name)

#### SYSTEM PROMPT (your high-performing version) ####
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

#####################################
# 1. ROBUST GPT CALL FUNCTION
#####################################
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
  
  types <- vapply(out$output, function(x) x$type, character(1))
  msg_idx <- which(types == "message")[1]
  if (is.na(msg_idx)) stop("No 'message' output found.")
  
  out$output[[msg_idx]]$content[[1]]$text
}

#####################################
# 2. BATCH CLASSIFICATION FUNCTION
#####################################
batch_classify <- function(df, system_prompt, batch_size = 30, retries = 3) {
  
  batches <- split(df, ceiling(seq_len(nrow(df)) / batch_size))
  
  results <- pbapply::pblapply(batches, function(batch) {
    
    batch_prompt <- paste0(
      system_prompt, "\n\n",
      "Classify each of the following Reddit posts as 'Yes' or 'No'. ",
      "Return ONLY a JSON array of strings.\n\n",
      paste0(
        seq_len(nrow(batch)), ". Subreddit: ", batch$subreddit, 
        "\nPost: ", batch$text, collapse = "\n\n"
      )
    )
    
    resp_text <- NULL
    for (i in seq_len(retries)) {
      resp_text <- tryCatch(
        gpt_call(batch_prompt),
        error = function(e) {
          message("API error attempt ", i, ": ", e$message)
          Sys.sleep(2^i)
          NULL
        }
      )
      if (!is.null(resp_text)) break
    }
    
    if (is.null(resp_text)) {
      batch$prediction <- rep(NA_character_, nrow(batch))
      return(batch)
    }
    
    cleaned <- gsub("```[a-zA-Z]*\\s*|```", "", resp_text) |> trimws()
    
    parsed <- tryCatch(
      jsonlite::fromJSON(cleaned),
      error = function(e) {
        stringr::str_extract_all(cleaned, "(?i)\\bYes\\b|\\bNo\\b")[[1]]
      }
    )
    
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

#####################################
# 3. MULTIPLE RUNS + MAJORITY VOTE
#####################################
runs <- 5   # ← increase if you want even more stability

for (i in seq_len(runs)) {
  message(sprintf("Starting pass %d/%d...", i, runs))
  classified <- batch_classify(df, system_prompt, batch_size = 30)
  cname <- paste0("pred_", model_label, "_run", i)
  df[[cname]] <- classified$prediction
}

# Majority vote: count how many Yes per row
prediction_cols <- grep(paste0("^pred_", model_label), names(df), value = TRUE)

df <- df |>
  mutate(
    yes_votes = rowSums(across(all_of(prediction_cols), \(x) x == "Yes")),
    majority_vote = if_else(
      yes_votes >= ceiling(runs / 2),
      "Yes", "No"
    )
  )

#####################################
# 4. SAVE FINAL OUTPUT
#####################################

timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

outfile <- sprintf("LLM output/full_predictions_%s_%s.feather",
                   model_label, timestamp)

arrow::write_feather(df, outfile)

cat("\n\n✅ Finished full classification with majority vote.\n")
cat("Saved to: ", outfile, "\n")

#####################################
# 5. SOME ADDITIONAL (NEAR) DEDUPLICATING
#####################################

library(textreuse)
library(igraph)

df <- arrow::read_feather(here("LLM output", "full_predictions_gpt51_20251210_181138.feather")) |>
  filter(majority_vote == "Yes") |>
  arrange(desc(created_utc))

# 0) Clean input
df2 <- df |>
  filter(!is.na(selftext), trimws(selftext) != "") |>
  mutate(doc_id = as.character(doc_id))

# 1) Named character vector
docs <- setNames(df2$selftext, df2$doc_id)

# 2) Corpus Setup
set.seed(1)
mh_fun <- minhash_generator(n = 200)

corpus <- TextReuseCorpus(
  text        = docs,
  tokenizer   = tokenize_ngrams,
  n           = 5,
  lowercase   = TRUE,
  keep_tokens = FALSE, # Saves RAM
  minhash_func = mh_fun
)

# 3) LSH and Comparison
# Bands = 50 means we catch loose matches (approx 37% similarity+), 
# but we filter strictly at 0.80 later. Good strategy for high recall.
buckets <- lsh(corpus, bands = 50)
cands   <- lsh_candidates(buckets)
pairs   <- lsh_compare(cands, corpus, jaccard_similarity)

# 4) Filter for strict matches
pairs2 <- pairs |>
  dplyr::filter(score >= 0.10) #set at low rate after visual inspection

# 5) Graph-based Deduplication
# Create graph from matches
g <- graph_from_data_frame(
  pairs2 |> transmute(from = as.character(a), to = as.character(b)),
  directed = FALSE
)

# Get cluster membership
memb <- components(g)$membership 

# Tag the original dataframe
df_keep <- df2 |>
  mutate(cluster = if_else(
    # Check if doc_id exists in the graph (is a duplicate)
    # If not in 'memb', it's a unique "solo" post
    doc_id %in% names(memb),
    paste0("cl_", memb[doc_id]),
    paste0("solo_", doc_id)
  )) |>
  # Group by cluster and keep the oldest
  group_by(cluster) |>
  arrange(created_utc, .by_group = TRUE) |>
  slice(1) |>
  ungroup()

# 6) Overview (Optional: to check what was dropped)
# 1. Define columns to keep (Add 'subreddit' here)
cols_needed <- c("doc_id", "author", "created_utc", "selftext", "subreddit")

# 2. Build the overview
overview <- pairs2 |>
  arrange(desc(score)) |>
  
  # Join Doc A details
  left_join(df2 |> select(all_of(cols_needed)), by = c("a" = "doc_id")) |>
  rename(
    author_a      = author, 
    created_utc_a = created_utc, 
    text_a        = selftext,
    subreddit_a   = subreddit  # <--- Renaming for A
  ) |>
  
  # Join Doc B details
  left_join(df2 |> select(all_of(cols_needed)), by = c("b" = "doc_id")) |>
  rename(
    author_b      = author, 
    created_utc_b = created_utc, 
    text_b        = selftext,
    subreddit_b   = subreddit  # <--- Renaming for B
  ) |>
  
  # Calculate time diff
  mutate(
    diff_seconds = as.numeric(created_utc_a) - as.numeric(created_utc_b)
  ) |>
  
  # Final selection
  transmute(
    similarity_score = score,
    doc_a = a, author_a, subreddit_a, created_utc_a, text_a, # Added subreddit_a
    doc_b = b, author_b, subreddit_b, created_utc_b, text_b, # Added subreddit_b
    diff_seconds
  )

overview <- overview |>
  mutate(diff_hours = diff_seconds/3600) |>
  select(similarity_score, created_utc_a, created_utc_b, subreddit_a, subreddit_b, author_a, author_b, diff_hours, text_a, text_b)

# View the result
head(overview)
# View results
print(paste("Original rows:", nrow(df2)))
print(paste("Rows after dedup:", nrow(df_keep)))

arrow::write_feather(
  df_keep,
  here("LLM Output", "majority_vote_gpt51_20251210_181138.feather")
)
