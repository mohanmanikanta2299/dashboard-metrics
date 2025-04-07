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

fetch_metrics() {
    repo=$1

    # Fetch repository details (includes open_issues_count)
    response=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                     -H "Accept: application/vnd.github.v3+json" \
                     "https://api.github.com/repos/hashicorp/$repo")

    # Validate response
    if [[ -z "$response" || "$response" == "null" ]]; then
        echo "{\"repo\":\"$repo\",\"open_issues\":0,\"open_prs\":0,\"has_workflows\":false,\"triggered_on_push_or_pr\":false}"
        return
    fi

    open_issues=$(echo "$response" | jq '.open_issues_count // 0')

    # Fetch open PR count separately
    pr_count=0
    page=1

    while :; do
        pr_response=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                             -H "Accept: application/vnd.github.v3+json" \
                             "https://api.github.com/repos/hashicorp/$repo/pulls?state=open&page=$page&per_page=100")

        count=$(echo "$pr_response" | jq 'if type == "array" then length else 0 end')

        pr_count=$((pr_count + count))

        # If fewer than 100 PRs are returned, it's the last page
        [[ $count -lt 100 ]] && break

        ((page++))
    done

    # Validate PR count
    if [[ -z "$pr_count" || "$pr_count" == "null" ]]; then
        pr_count=0
    fi

    # Subtract PR count from open issues count (actual issues count)
    actual_issues=$((open_issues - pr_count))

    # Check for workflow files
    workflows_response=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                                -H "Accept: application/vnd.github.v3+json" \
                                "https://api.github.com/repos/hashicorp/$repo/contents/.github/workflows")

    has_workflows=false
    triggered_on_push_or_pr=false

    # Check if the response is an array (i.e., directory exists and contains files)
    if echo "$workflows_response" | jq -e '. | type == "array"' >/dev/null; then
        # Check if any .yml or .yaml workflow files exist
        has_workflows=$(echo "$workflows_response" | jq '[.[] | select(.type == "file" and (.name | endswith(".yml") or endswith(".yaml")))] | length > 0')

        if [ "$has_workflows" = true ]; then
            # Loop through each workflow file and check if it triggers on push or pull_request
            for url in $(echo "$workflows_response" | jq -r '.[] | select(.type == "file") | select(.name | endswith(".yml") or endswith(".yaml")) | .download_url'); do
                yaml_content=$(curl -s "$url")

                if echo "$yaml_content" | yq -e '
                    .on as $on |
                    ($on == "push" or
                     $on == "pull_request" or
                     ($on | type == "array" and ($on[] == "push" or $on[] == "pull_request")) or
                     ($on | type == "object" and (has("push") or has("pull_request")))
                    )
                ' >/dev/null; then
                    triggered_on_push_or_pr=true
                    break
                fi
            done
        fi
    fi

    echo "{\"repo\":\"$repo\",\"open_issues\":$actual_issues,\"open_prs\":$pr_count,\"has_workflows\":$has_workflows,\"triggered_on_push_or_pr\":$triggered_on_push_or_pr}"
}

export -f fetch_metrics

# Use xargs for parallel execution
{
    echo -n "["
    cat "$REPO_FILE" | xargs -I{} -P $NUM_JOBS bash -c 'fetch_metrics "$@"' _ {} | paste -sd "," -
    echo "]"
} | jq '.' > "$OUTPUT_FILE"

echo "Metrics saved to $OUTPUT_FILE"