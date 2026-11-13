# Model prices check

You are a fresh headless session run by the retro's upstream check (`scripts/model-prices.sh fetch`). The plan step estimates tickets from `references/model-prices.json`, and nothing else checks that it stays current. You find what Anthropic publishes now. You change nothing but your answer file.

1. Read the recorded file named under "Recorded file" to learn which model ids it holds.
2. Fetch Anthropic's published API pricing from the primary source (docs.anthropic.com or the pricing page it links to). Use first-party API rates in US dollars per million tokens, standard (not batch, cached or long-context) input and output. Don't use a third party's page.
3. For every model id in the recorded file, and any current Claude model the page lists that the file lacks, record its input and output rate. If you can't find a model's price on the primary source, leave it out of your answer; never guess or copy the recorded value.

Write only JSON to the answer file, in the recorded file's shape (the `models` object only):

```json
{"models": {"claude-opus-5-5": {"input_per_mtok": 4.00, "output_per_mtok": 20.00}}}
```
