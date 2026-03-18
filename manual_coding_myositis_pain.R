rm(list = ls()[!sapply(ls(), function(x) is.function(get(x)))])
cat("\014")

library(tidyverse)
library(here)
source(here("config.R"))

file_path <- file.path(DATA_PATH, "data", "myositis_submissions_2005_july2025_clean.feather")

df <- arrow::read_feather(file_path) |>
  filter(!is.na(text) & trimws(text) != "")

df |>
  count(id) |> 
  filter(n > 1)

double_case <- "bmqw0f"

hc <- read.csv("/Users/peterkerkhof/Library/CloudStorage/OneDrive-VrijeUniversiteitAmsterdam/Onderzoek/R/reddit/reddit-data-hub/projects/myositis-pain-data/LLM output/pain_posts_llm_handcoded.csv") |>
  select(id)

hc <- hc |>
  inner_join(df, by = "id") |>
  select(id, subreddit, title, selftext, text) |>
  slice(-178)



writexl::write_xlsx(hc, file.path(DATA_PATH, "LLM output/manual_coding_myositis_pain_MH.xlsx"))
