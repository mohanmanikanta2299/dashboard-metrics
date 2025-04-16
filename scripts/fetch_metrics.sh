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

    heimdall_url="https://heimdall.hashicorp.services/site/assets/$repo"

    # Fetch repository details (includes open_issues_count)
    response=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                     -H "Accept: application/vnd.github.v3+json" \
                     "https://api.github.com/repos/hashicorp/$repo")

    # Validate response
    if [[ -z "$response" || "$response" == "null" ]]; then
        echo "{\"repo\":\"$repo\",\"forked_from\":\"--\",\"open_issues\":0,\"open_prs\":0,\"triggered_on_push_or_pr\":false,\"release_version\":\"--\",\"tag\":\"--\",\"heimdall_url\":\"$heimdall_url\",\"test_coverage\":\"--\"}"
        return
    fi

    # Check id repo is a fork
    is_fork=$(echo "$response" | jq '.fork // false')
    forked_from="--"
    if [[ "$is_fork" == "true" ]]; then
        forked_from=$(echo "$response" | jq -r '.parent.full_name // "--"')
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

    # Check if the response is an array (i.e., .github/workflows exists)
    if echo "$workflows_response" | jq -e 'type == "array"' >/dev/null; then
        has_workflows=$(echo "$workflows_response" | jq '[.[] | select(.type == "file" and (.name | test("\\.ya?ml$"))) ] | length > 0')

        if [ "$has_workflows" = true ]; then
            # Get all .yml or .yaml download URLs
            mapfile -t workflow_urls < <(echo "$workflows_response" | jq -r '
                .[] 
                | select(.type == "file") 
                | select(.name | test("\\.ya?ml$")) 
                | .download_url
            ')

            for url in "${workflow_urls[@]}"; do
                yaml_content=$(curl -s "$url")

                # Check if the workflow triggers on push or pull_request
                if echo "$yaml_content" | yq eval -e '
                 (
                    (.on == "push") or
                    (.on == "pull_request") or
                    ( (.on | type == "!!seq") and (.on[] == "push" or .on[] == "pull_request") ) or
                    ( (.on | type == "!!map") and (has("push") or has("pull_request")) )
                 )
                ' - >/dev/null 2>&1; then
                    triggered_on_push_or_pr=true
                    break
                fi

                if echo "$yaml_content" | grep -E '^\s*on:\s*$' >/dev/null || \
                   echo "$yaml_content" | grep -E '^\s*on:\s*(push|pull_request|\[.*(push|pull_request).*\])' >/dev/null; then
                    triggered_on_push_or_pr=true
                    break
                fi
            done
        fi
    fi

    test_coverage="--"

    latest_merged_pr=$(curl -s -H "Authorizatin: Bearer $GITHUB_APP_TOKEN" \
                             -H "Accept: application/vnd.github.v3+json" \
                             "https://api.github.com/repos/hashicorp/$repo/pulls?state=closed&sort=updated&direction=desc&per_page=10" \
                             | jq -e '[.[] | select(.merged_at != null)] | first // empty')
    
    if [[ -n "$latest_merged_pr" && "$latest_merged_pr" != "null" ]]; then
        pr_merge_commit_sha=$(echo "$latest_merged_pr" | jq -r '.merge_commit_sha // empty')
        echo "✅ Found merged commit SHA: $pr_merge_commit_sha" >&2

        if [[ -n "$pr_merge_commit_sha" ]]; then
            run_id=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                           -H "Accept: application/vnd.github.v3+json" \
                           "https://api.github.com/repos/hashicorp/$repo/actions/runs?per_page=10" \
                           | jq -e --arg sha "$pr_merge_commit_sha" '[.workflow_runs[] | select(.head_sha == $sha and .status == "completed" and .conclusion == "success")] | .[0].id // empty')

            if [[ -n "$run_id" ]]; then
                echo "✅ Found run_id: $run_id" >&2

                artifact_url=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                                     -H "Accept: application/vnd.github.v3+json" \
                                     "https://api.github.com/repos/hashicorp/$repo/actions/runs/$run_id/artifacts" \
                                     | jq -e -r '.artifacts[] | select(.name | test("(?i)^coverage-report")) | .archive_download_url' \
                                     | head -n1)

                if [[ -n "$artifact_url" ]]; then
                    echo "📦 Artifact URL: $artifact_url" >&2
                    tmpdir=$(mktemp -d)
                    curl -s -L -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                          -H "Accept: application/vnd.github.v3+json" \
                          "$artifact_url" -o "$tmpdir/artifact.zip"
                    unzip -q "$tmpdir/artifact.zip" -d "$tmpdir"
                    coverage_file=$(find "$tmpdir" -type f -name "coverage.out" | head -n1)

                    if [[ -f "$coverage_file" ]]; then
                        echo "✅ Found coverage.out" >&2
                        echo "🔍 Contents of $coverage_file:" >&2
                        cat "$coverage_file"

                        total=0
                        covered=0
                        while read -r line; do
                           stmts=$(echo "$line" | awk '{print $3}')
                           hits=$(echo "$line" | awk '{print $4}')
                           total=$((total + stmts))
                           if [[ "$hits" -gt 0 ]]; then
                               covered=$((covered + stmts))
                           fi
                        done < "$coverage_file"

                        if [[ "$total" -gt 0 ]]; then
                            test_coverage=$(awk "BEGIN { printf \"%.1f%%\", ($covered/$total)*100 }")
                            echo "📊 Extracted coverage: $test_coverage" >&2
                        else
                            echo "⚠️ Invalid or missing total coverage in $coverage_file" >&2
                        fi
                    else
                       echo "⚠️ coverage.out not found" >&2
                    fi
                    rm -rf "$tmpdir"
                fi
            else
                echo "❌ No successful workflow run found for commit $pr_merge_commit_sha" >&2
            fi
        fi
    fi

    # Get the latest release version
    release_response=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                             -H "Accept: application/vnd.github.v3+json" \
                             "https://api.github.com/repos/hashicorp/$repo/releases/latest")

    release_version=$(echo "$release_response" | jq -r '.tag_name // empty')

    if [[ -z "$release_version" || "$release_version" == "null" ]]; then
        tag=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                    -H "Accept: application/vnd.github.v3+json" \
                    "https://api.github.com/repos/hashicorp/$repo/tags" \
                    | jq -r '.[0].name // empty')
        release_version="--"
    fi

    if [[ -z "$tag" || "$tag" == "null" ]]; then
        tag="--"
    fi

    echo "{\"repo\":\"$repo\",\"forked_from\":\"$forked_from\",\"open_issues\":$actual_issues,\"open_prs\":$pr_count,\"triggered_on_push_or_pr\":$triggered_on_push_or_pr,\"release_version\":\"$release_version\",\"tag\":\"$tag\",\"heimdall_url\":\"$heimdall_url\",\"test_coverage\":\"$test_coverage\"}"
}

export -f fetch_metrics

# Use xargs for parallel execution
{
    echo -n "["
    cat "$REPO_FILE" | xargs -I{} -P $NUM_JOBS bash -c 'fetch_metrics "$@"' _ {} | paste -sd "," -
    echo "]"
} | jq '.' > "$OUTPUT_FILE"

echo "Metrics saved to $OUTPUT_FILE"