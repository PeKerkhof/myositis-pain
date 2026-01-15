# Myositis & Pain – Project Overview

This repository contains all project-specific scripts, data files, and analyses for the
**Myositis and Pain** Reddit project.

The README documents **where data come from, where intermediate files are stored,
and which scripts produce which outputs**.

---

## Prerequisites

### R Environment
- **R version**: 4.0 or higher recommended
- **RStudio**: Optional but recommended for running .qmd files

### Required R Packages
The following R packages are required to run the analysis scripts:

**Data manipulation & I/O:**
- tidyverse, arrow, feather, here, glue

**Text processing & NLP:**
- tidytext, udpipe, stringr, stringi, SnowballC, textstem, pluralize, cld2

**LLM API & evaluation:**
- httr2, jsonlite, caret

**Near-duplicate detection:**
- textreuse (MinHash/LSH algorithms)

**Network analysis:**
- igraph, tidygraph, ggraph, widyr

**Visualization:**
- ggplot2 (included in tidyverse), ggthemes, viridis, RColorBrewer, wordcloud, ggvenn

**Utilities:**
- lubridate, purrr, furrr, pbapply, scales, knitr, kableExtra, gt, gtExtras, htmltools, forcats, tidylo, grid, googlesheets4

You can install all required packages using:
```r
install.packages(c("tidyverse", "arrow", "feather", "here", "glue", "tidytext",
                   "udpipe", "stringr", "stringi", "SnowballC", "textstem",
                   "pluralize", "cld2", "httr2", "jsonlite", "caret", "textreuse",
                   "igraph", "tidygraph", "ggraph", "widyr", "ggthemes", "viridis",
                   "RColorBrewer", "wordcloud", "ggvenn", "lubridate", "purrr",
                   "furrr", "pbapply", "scales", "knitr", "kableExtra", "gt",
                   "gtExtras", "htmltools", "forcats", "tidylo", "grid", "googlesheets4"))
```

### External Dependencies
- **udpipe language model**: The project uses `english-ewt-ud-2.5-191206.udpipe` for lemmatization. Download from [udpipe models](https://ufal.mff.cuni.ff.cz/udpipe/models) if not present.

### API Keys
- **OpenAI API Key**: Required for LLM-based classification scripts (`myositis_pain_GPT5_mini-with_evaluation.R` and `myositis_pain_GPT5_all_data.R`)

  Set the environment variable before running these scripts:
  ```bash
  export OPENAI_API_KEY="your-api-key-here"
  ```

  Or in R:
  ```r
  Sys.setenv(OPENAI_API_KEY = "your-api-key-here")
  ```

---

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
  `myositis_pain_importing_the_data.qmd`
- Description:
  Imports query results and subreddit archives and merges them into a single dataset.
  - Section 1: Setup and configuration
  - Section 2: Load query results from Academic Torrents data
  - Section 3: Load subreddit archives from Arctic Shift
  - Section 4: Merge and deduplicate datasets
- Output:
  `DATA_PATH/data/myositis_submissions_incl_subreddits_2005_july2025.feather`

---

## 4. Data cleaning & preprocessing

- Script:
  `myositis_pain_cleaning_the_data.qmd`
- Description:
  Text cleaning, preprocessing, and lemmatization with case flow tracking.
  - Section 1-2: Setup and data loading
  - Section 3: Remove deleted/removed posts
  - Section 4: Remove bot and spam accounts
  - Section 5: Filter non-English posts
  - Section 6: Deduplicate posts
  - Section 7: Create combined text field
  - Section 8: Lemmatize text (udpipe)
  - Section 9: Case flow summary table
  - Section 10: Save cleaned data
- Output:
  `DATA_PATH/data/myositis_submissions_2005_july2025_clean.feather`

---

## 5. LLM-based relevance selection

Classifies posts to identify those where the author refers to their **own** myositis diagnosis.

### 5.1 Model evaluation
- Script:
  `myositis_pain_GPT5_mini-with_evaluation.R`
- Description:
  Evaluates GPT-5.1 classification performance using hand-coded ground truth.
  - Sections 1-5: Setup, configuration, load evaluation data
  - Section 6-7: API call and batch classification functions
  - Section 8: Run 5 classification passes for majority voting
  - Sections 9-12: Calculate metrics (Accuracy, F1, Precision, Recall), save results
- Input:
  `DATA_PATH/LLM output/pain_posts_llm_handcoded.csv`

### 5.2 Full dataset classification
- Script:
  `myositis_pain_GPT5_all_data.R`
- Description:
  Applies validated GPT-5.1 classifier to full dataset with near-duplicate removal.
  - **Part A - Classification** (Sections 1-10): Load data, run 5 passes, majority vote
  - **Part B - Deduplication** (Sections 11-20): MinHash/LSH near-duplicate detection, graph-based clustering
- Output:
  `DATA_PATH/LLM output/majority_vote_gpt51_YYYYMMDD_HHMMSS.feather`

---

## 6. Analysis & outputs

- Script:
  `myositis_pain_analyzing_the_data.qmd`
- Description:
  Main analysis pipeline for pain expression in myositis posts.
  - Section 1: Setup and data loading
  - Section 2: Descriptive statistics over time
  - Section 3: Pain lexicon preparation (published + custom terms)
  - Section 4: Pain mentions analysis
  - Section 5: Pain description analysis (bigrams)
  - Section 6: Body regions in pain posts
  - Section 7: Pain centrality score calculation
  - Section 8: Semantic network analysis (Jaccard co-occurrence)
  - Section 9: Network centrality analysis
  - Section 10: Community detection (Louvain algorithm)
- Outputs:
  - Myositis_Semantic_Network_HighRes.png

---

## Citation

If you use this code or methodology in your research, please cite:

**[Add your publication details here when available]**

For now, you can cite this repository:
```
Kerkhof, P. (2025). Myositis & Pain: Analysis of pain expression in myositis-related
Reddit posts. GitHub repository. https://github.com/PeKerkhof/myositis-pain
```

---

## Contact

For questions or collaboration inquiries, please [open an issue](https://github.com/PeKerkhof/myositis-pain/issues) or contact the repository owner.