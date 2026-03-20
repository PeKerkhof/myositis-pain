rm(list = ls()[!sapply(ls(), function(x) is.function(get(x)))])
cat("\014")

options(scipen = 999)  # Avoid scientific notation in tables/outputs

library(tidyverse)
library(here)
library(arrow)
library(irr)

source(here("config.R"))

#pk original file
df_pk <- read_csv(file.path(DATA_PATH, "LLM Output/pain_posts_llm_handcoded.csv"))

#mr first coding
df_mr <- readxl::read_xlsx(file.path(DATA_PATH, "LLM Output/manual_coding_myositis_pain_MR.xlsx"))

df_dis <- readxl::read_xlsx(file.path(DATA_PATH, "LLM Output/disagreements_evaluated2_MR.xlsx")) |>
  select(claude_code, pk, mr, new_code_mr, everything())

df_dis$disagree_pk <- df_dis$claude_code != df_dis$pk
df_dis$pk_new <- ifelse(df_dis$disagree_pk, df_dis$claude_code, df_dis$pk)


df_dis$disagree_mr <- df_dis$claude_code != df_dis$mr
df_dis$mr_new <- ifelse(df_dis$disagree_mr, df_dis$claude_code, df_dis$mr)

df_dis <- df_dis |>
  select(12:15, everything())

# Merge on id
df_combined <- inner_join(
  df_pk |> select(id, ground_truth),
  df_mr |> select(id, manual_code),
  by = "id"
)

# Confusion matrix
table(df_combined$ground_truth, df_combined$manual_code)
table(Coder_1 = df_combined$ground_truth, Coder_2 = df_combined$manual_code)




library(caret)
confusionMatrix(factor(df_combined$ground_truth), factor(df_combined$manual_code))

# Percent agreement
mean(df_combined$ground_truth == df_combined$manual_code)

# Cohen's kappa
kappa2(df_combined |> select(ground_truth, manual_code))

# Disagreements
df_disagreements <- df_combined |>
  filter(ground_truth != manual_code) |>
  left_join(df_mr |> select(id, subreddit, title, selftext), by = "id") |>
  select(id, subreddit, title, selftext, ground_truth, manual_code) |>
  rename(pk = ground_truth, mr = manual_code)

#writexl::write_xlsx(df_disagreements, file.path(DATA_PATH, "LLM Output/disagreements.xlsx"))


df_combined$corrected <- df_dis$claude_code[match(df_combined$id, df_dis$id)]

df_combined$final <- ifelse(!is.na(df_combined$corrected), df_combined$corrected, df_combined$ground_truth)


df_pk$final <- df_combined$final[match(df_pk$id, df_combined$id)]

write_csv(df_pk, (file.path(DATA_PATH, "LLM Output/pain_posts_llm_handcoded_corrected.csv")))

DATA_PATH

          