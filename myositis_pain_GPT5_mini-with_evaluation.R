#### Clean environment ####
rm(list = ls()[!sapply(ls(), function(x) is.function(get(x)))])
cat("\014")

#### Load Required Libraries ####
library(tidyverse)
library(pbapply)
library(ellmer)
library(jsonlite)
library(here)
library(caret)
library(future)
library(future.apply)
library(httr2)

#### Load API Key ####
api_key <- Sys.getenv("OPENAI_API_KEY")
if (api_key == "") stop("Error: OPENAI_API_KEY is not set.")

#### Load Data ####
file_path <- here("LLM output", "pain_posts_llm_handcoded.csv")

df <- readr::read_csv(file_path, show_col_types = FALSE) |>
  select(subreddit, ground_truth, text) |>
  filter(!is.na(text) & trimws(text) != "")

#### Define GPT model ####
model_name <- "gpt-5.1"

# Create safe label for column and file names
model_label <- gsub("[^A-Za-z0-9]", "", model_name)

#### System prompt ####
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


#####################################
# 0. INITIALIZATION & API KEY
#####################################
model_times <- list()
api_key <- Sys.getenv("OPENAI_API_KEY")

#####################################
# 1. ROBUST API CALLER
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
# 2. BATCH PROCESSOR
#####################################
batch_classify <- function(df, system_prompt, batch_size = 10, retries = 3) {
  
  batches <- split(df, ceiling(seq_len(nrow(df)) / batch_size))
  
  results <- pbapply::pblapply(batches, function(batch) {
    
    batch_prompt <- paste0(
      system_prompt, "\n\n",
      "Classify each of the following Reddit posts as 'Yes' or 'No'. ",
      "Return ONLY a JSON array of strings.\n\n",
      paste0(seq_len(nrow(batch)), ". ", batch$text, collapse = "\n\n")
    )
    
    resp_text <- NULL
    for (i in seq_len(retries)) {
      resp_text <- tryCatch(
        gpt_call(batch_prompt),
        error = function(e) {
          message("API error on attempt ", i, ": ", e$message)
          Sys.sleep(2^i)
          NULL
        }
      )
      if (!is.null(resp_text)) break
    }
    
    if (is.null(resp_text)) {
      batch$pred <- rep(NA_character_, nrow(batch))
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
    
    batch$pred <- tools::toTitleCase(tolower(parsed))
    batch
  })
  
  bind_rows(results)
}

#####################################
# 3. RUNTIME LOOP
#####################################
runs <- 5

for (i in seq_len(runs)) {
  message(sprintf("Starting Pass %d/%d...", i, runs))
  start <- Sys.time()
  
  classified <- batch_classify(df, system_prompt, batch_size = 30)
  
  cname <- paste0("pred_", model_label, "_run", i)
  df[[cname]] <- classified$pred
  
  model_times[[cname]] <- as.numeric(difftime(Sys.time(), start, units = "secs"))
}

###################################
# 4. METRICS USING CARET
###################################
prediction_cols <- grep(paste0("^pred_", model_label), names(df), value = TRUE)

metrics_df <- purrr::map_dfr(prediction_cols, function(col) {
  
  truth <- factor(df$ground_truth, levels = c("Yes", "No"))
  pred  <- factor(df[[col]], levels = c("Yes", "No"))
  
  cm <- caret::confusionMatrix(pred, truth, positive = "Yes")
  
  tibble(
    Model = col,
    Accuracy = cm$overall["Accuracy"],
    F1 = cm$byClass["F1"],
    Precision = cm$byClass["Precision"],
    Recall = cm$byClass["Recall"],
    TP = cm$table["Yes", "Yes"],
    FP = cm$table["Yes", "No"],
    FN = cm$table["No",  "Yes"],
    TN = cm$table["No",  "No"],
    Total_Time_Sec = model_times[[col]]
  )
})

###################################
# 5. MAJORITY VOTE
###################################
df <- df |>
  mutate(
    yes_votes = rowSums(across(all_of(prediction_cols), \(x) x == "Yes"), na.rm = TRUE),
    majority = if_else(
      yes_votes >= ceiling(length(prediction_cols) / 2),
      "Yes", 
      "No"
    )
  )

cm_final <- confusionMatrix(
  factor(df$majority, levels = c("Yes", "No")),
  factor(df$ground_truth, levels = c("Yes", "No")),
  positive = "Yes"
)

metrics_df <- bind_rows(
  metrics_df,
  tibble(
    Model = paste0(model_label, "_MajorityVote"),
    Accuracy = cm_final$overall["Accuracy"],
    F1 = cm_final$byClass["F1"],
    Precision = cm_final$byClass["Precision"],
    Recall = cm_final$byClass["Recall"],
    TP = cm_final$table["Yes", "Yes"],
    FP = cm_final$table["Yes", "No"],
    FN = cm_final$table["No",  "Yes"],
    TN = cm_final$table["No",  "No"],
    Total_Time_Sec = NA
  )
)

###################################
# 6. SAVE EVERYTHING
###################################
timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

write_csv(df, sprintf("LLM output/results_%s_%s.csv", model_label, timestamp))
write_csv(metrics_df, sprintf("LLM output/metrics_%s_%s.csv", model_label, timestamp))

print(metrics_df)
cat("\n✅ Finished — Model:", model_name, "(", model_label, ")\n")