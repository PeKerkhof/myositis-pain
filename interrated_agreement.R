rm(list = ls()[!sapply(ls(), function(x) is.function(get(x)))])
cat("\014")

options(scipen = 999)  # Avoid scientific notation in tables/outputs

library(tidyverse)
library(here)
library(arrow)
library(irr)

source(here("config.R"))

df_pk <- read_csv(file.path(DATA_PATH, "LLM Output/pain_posts_llm_handcoded.csv"))

df_mr <- readxl::read_xlsx(file.path(DATA_PATH, "LLM Output/manual_coding_myositis_pain_MR.xlsx"))

# Merge on id
df_combined <- inner_join(
  df_pk |> select(id, ground_truth),
  df_mr |> select(id, manual_code),
  by = "id"
)

# Confusion matrix
table(df_combined$ground_truth, df_combined$manual_code)

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

writexl::write_xlsx(df_disagreements, file.path(DATA_PATH, "LLM Output/disagreements.xlsx"))

          
          