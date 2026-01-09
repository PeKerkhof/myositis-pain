# Myositis & Pain – Project Overview

This repository contains all project-specific scripts, data files, and analyses for the
**Myositis and Pain** Reddit project.

The README documents **where data come from, where intermediate files are stored,
and which scripts produce which outputs**.


## Setup Instructions

### Data Configuration

This project references external data stored outside the repository in a centralized data hub.

1. Copy `config_template.R` to `config.R`
2. Edit `config.R` and update paths:
   - `REDDIT_DATA_PATH` - path to your reddit-data-hub location
   - `DATA_PATH` - path to `reddit-data-hub/projects/myositis-pain-data/`
3. The `config.R` file is excluded from Git (contains local paths)

### Required Data Structure

The project data folder (`DATA_PATH`) should contain:
```
myositis-pain-data/
├── data/                           # Cleaned data files (feather)
└── LLM output/                     # LLM classification results
```

The reddit data hub (`REDDIT_DATA_PATH`) should contain:
- `queries/query-output/` - Queries & Query results
- `subreddits/data/myositis/` - Subreddit archives

---

## 1. Raw data sources

Raw Reddit data were collected from two sources:

### 1.1 Reddit data dumps (Academic Torrents)
- Source: https://academictorrents.com
- Query date: 2025-11-08
- Script:
  reddit-data-hub/queries/query_parquet_myositis.R
- Output file:
  reddit-data-hub/queries/query-output/myositis_submissions_20250910.feather

### 1.2 Subreddit archives (Arctic Shift)
- Source: https://arctic-shift.photon-reddit.com/download-tool
- Subreddits: three myositis-related subreddits
- Storage location:
  reddit-data-hub/subreddits/data/myositis/

---

## 2. Project directory

All project-specific work is located in:

myositis-pain/

This directory contains all scripts, processed data, and outputs used for analysis.

---

## 3. Data import & integration

- Script:
  myositis_pain_importing_the_data.qmd
- Description:
  Imports query results and subreddit archives and merges them into a single dataset.
- Output:
  DATA_PATH/data/myositis_submissions_incl_subreddits_2005_july2025.feather

---

## 4. Data cleaning & preprocessing

- Script:
  myositis_pain_cleaning_the_data.qmd
- Description:
  Text cleaning and lemmatization.
- Output:
  DATA_PATH/data/myositis_submissions_2005_july2025_clean.feather

---

## 5. LLM-based relevance selection

### 5.1 Model evaluation
- Script:
  myositis_pain_GPT5_mini_with_evaluation.R
- Description:
  Evaluates GPT-5.1 performance using a hand-coded reference set (n = 200).

### 5.2 Full dataset classification
- Script:
  myositis_pain_GPT5_all_data.R
- Description:
  Applies GPT-5.1 to the full cleaned dataset.
- Output:
  DATA_PATH/LLM output/majority_vote_gpt51_20251210_181138.feather

---

## 6. Analysis & outputs

- Script:
  myositis_pain_analyses.qmd
- Outputs:
  - Myositis_Semantic_Network_HighRes.png