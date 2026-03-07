# Content Curation Skill

## Purpose
Grade and categorize Telegram channel messages for topic-specific digest publishing.

## Grading Criteria

### Score Scale (1-10)
- **1-2**: Spam, ads, irrelevant content, duplicates
- **3-4**: Low value — generic announcements, old news, vague posts
- **5-6**: Moderate value — relevant topic, some insight, worth including in digest
- **7-8**: High value — significant news, unique analysis, actionable insights
- **9-10**: Exceptional — breaking news, major releases, transformative developments

### Topic Matching
Messages are matched to groups defined in `agent/topics.json`. A message can match multiple groups. The grader uses keyword matching AND semantic understanding — a message about "new AI model benchmarks" matches "AI News & Dev Tools" even without exact keyword hits.

### Summary Style
- One line, max 100 characters
- Lead with the action/news, not the source
- Use active voice
- No clickbait, no hype words
- Examples:
  - Good: "OpenAI releases GPT-5 with real-time reasoning"
  - Bad: "BREAKING: You won't believe what OpenAI just did!"
  - Good: "New framework cuts LLM inference cost by 40%"
  - Bad: "Amazing new framework for AI"

## Quality Signals (boost score)
- Original research or analysis
- First-hand announcements (from the company itself)
- Quantitative results (benchmarks, metrics)
- Practical tutorials or guides
- Open-source releases

## Noise Signals (lower score)
- Reposts of widely-known news (>24h old)
- Promotional content without substance
- Vague predictions or opinions without evidence
- Engagement bait ("What do you think?")
- Purely visual content without meaningful text
