library(tidyverse)
library(readxl)
library(here)

source(here("config.R"))

df <- read_excel(file.path(DATA_PATH, "LLM output", "pain_posts_llm_results_20251207_1615.xlsx")) |>
  select(id, subreddit, title, selftext, text, my_vote, majority_vote) |>
  rename(ground_truth = my_vote, majority_vote_gpt4o = majority_vote)

df <- df |>
  mutate(
    ground_truth = if_else(as.character(ground_truth) %in% c("1", "Yes"), "Yes", "No"),
    majority_vote_gpt4o = if_else(as.character(majority_vote_gpt4o) %in% c("1", "Yes"), "Yes", "No")
  ) |>
  mutate(
    ground_truth = as.factor(ground_truth),
    majority_vote_gpt4o = as.factor(majority_vote_gpt4o)
  ) 

# Rows to flip Yes → No
yes_to_no <- c(1, 4, 8, 9, 12)

# Rows to flip No → Yes
no_to_yes <- c(16, 20, 21, 22)

# Make a copy (recommended)
df_disagree <- df_disagree |>
  mutate(ground_truth_corrected = ground_truth)
df_disagree2 <- df_disagree

# Apply changes
df_disagree2$ground_truth_corrected[yes_to_no] <- "No"
df_disagree2$ground_truth_corrected[no_to_yes] <- "Yes"

# If ground_truth is a factor, reset levels to avoid unused levels
df_disagree2$ground_truth_corrected <- factor(df_disagree2$ground_truth_corrected, levels = c("No", "Yes"))

df_joined <- df |>
  left_join(
    df_disagree2 |> select(text, ground_truth_corrected),
    by = "text"
  )


df_joined <- df_joined |>
  mutate(
    ground_truth = if_else(
      !is.na(ground_truth_corrected),
      ground_truth_corrected,
      ground_truth
    )
  )

df <- df_joined 

write_csv(df, file.path(DATA_PATH, "LLM output", "pain_posts_llm_handcoded.csv"))

library(caret)
# 4. Confusion matrix (positive = "Yes")
cm <- confusionMatrix(df$majority_vote_gpt4o, df$ground_truth, positive = "Yes")

# Metrics
cm$byClass[c("Precision", "Recall", "F1", "Specificity")]
cm$overall["Accuracy"]

