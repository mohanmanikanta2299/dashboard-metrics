#!/bin/bash
set -e

REPO_FILE="repos.txt"
OUTPUT_FILE="metrics.json"
NUM_JOBS=10  # Number of parallel jobs

# Ensure repo file exists
if [[ ! -f "$REPO_FILE" ]]; then
    echo "Repository file '$REPO_FILE' not found!"
    exit 1
fi

if [[ -z "$GITHUB_OWNER" ]]; then
    echo "Error: GITHUB_OWNER is not set!" >&2
    exit 1
fi

fetch_metrics() {
    repo=$1

    # Fetch repository details (includes open_issues_count)
    response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
                     -H "Accept: application/vnd.github.v3+json" \
                     "https://api.github.com/repos/hashicorp/$repo")

    # Validate response
    if [[ -z "$response" || "$response" == "null" ]]; then
        echo "{\"repo\":\"$repo\",\"open_issues\":0,\"open_prs\":0}"
        return
    fi

    open_issues=$(echo "$response" | jq '.open_issues_count // 0')

    # Fetch open PR count separately
    pr_response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
                         -H "Accept: application/vnd.github.v3+json" \
                         "https://api.github.com/repos/hashicorp/$repo/pulls?state=open")

    pr_count=$(echo "$pr_response" | jq 'if type == "array" then length else 0 end')

    # Validate PR count
    if [[ -z "$pr_count" || "$pr_count" == "null" ]]; then
        pr_count=0
    fi

    # Print JSON object without formatting
    echo "{\"repo\":\"$repo\",\"open_issues\":$open_issues,\"open_prs\":$pr_count}"
}


export -f fetch_metrics  # Export function so it's available in subshells

# Use xargs for parallel execution
{
    echo -n "["
    cat "$REPO_FILE" | xargs -I{} -P $NUM_JOBS bash -c 'fetch_metrics "$@"' _ {} | paste -sd "," -
    echo "]"
} | jq '.' > "$OUTPUT_FILE"

echo "Metrics saved to $OUTPUT_FILE"