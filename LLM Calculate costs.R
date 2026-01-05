library(reticulate)

estimate_gpt51_cost <- function(
    text_vector,
    system_prompt,
    batch_size = 30,
    output_tokens_per_item = 2,
    input_cost_per_million = 1.25,
    output_cost_per_million = 10
) {
  library(reticulate)
  library(dplyr)
  library(stringr)
  
  # Load tokenizer
  tiktoken <- import("tiktoken")
  enc <- tiktoken$get_encoding("cl100k_base")
  
  # Tokenize posts
  message("Tokenizing posts...")
  post_tokens <- sapply(text_vector, function(x) length(enc$encode(x)))
  
  # Tokenize prompt once
  prompt_tokens <- length(enc$encode(system_prompt))
  
  # Number of batches
  n <- length(text_vector)
  n_batches <- ceiling(n / batch_size)
  
  # Prompt tokens per batch
  total_prompt_tokens <- prompt_tokens * n_batches
  
  # Total input tokens (posts + prompts)
  total_input_tokens <- sum(post_tokens) + total_prompt_tokens
  
  # Total output tokens
  total_output_tokens <- n * output_tokens_per_item
  
  # Cost calculations
  input_cost  <- total_input_tokens  / 1e6 * input_cost_per_million
  output_cost <- total_output_tokens / 1e6 * output_cost_per_million
  total_cost  <- input_cost + output_cost
  
  # Summary statistics
  summary_stats <- list(
    n_items = n,
    mean_post_tokens  = mean(post_tokens),
    median_post_tokens = median(post_tokens),
    p95_post_tokens = quantile(post_tokens, 0.95),
    max_post_tokens = max(post_tokens),
    total_post_tokens = sum(post_tokens),
    prompt_tokens_per_batch = prompt_tokens,
    total_prompt_tokens = total_prompt_tokens,
    total_input_tokens = total_input_tokens,
    total_output_tokens = total_output_tokens
  )
  
  # Results
  list(
    summary = summary_stats,
    cost = list(
      input_cost = input_cost,
      output_cost = output_cost,
      total_cost = total_cost
    )
  )
}
df <- arrow::read_feather("data/myositis_submissions_2005_july2025_clean.feather")


result <- estimate_gpt51_cost(
  text_vector = df$text,
  system_prompt = system_prompt,   # from your classifier script
  batch_size = 30
)

result$cost
result$summary
