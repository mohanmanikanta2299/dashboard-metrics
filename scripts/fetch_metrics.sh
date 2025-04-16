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

     # Get the latest merged PR
latest_merged_pr=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/hashicorp/$repo/pulls?state=closed&sort=updated&direction=desc&per_page=10")

# Ensure valid JSON
if ! echo "$latest_merged_pr" | jq . >/dev/null 2>&1; then
    echo "❌ Failed to fetch PRs for $repo"
    exit 1
fi

latest_merged_pr=$(echo "$latest_merged_pr" | jq '[.[] | select(.merged_at != null)] | first')

test_coverage="--"

if [[ "$latest_merged_pr" != "null" && -n "$latest_merged_pr" ]]; then
    pr_number=$(echo "$latest_merged_pr" | jq '.number')
    pr_merge_commit_sha=$(echo "$latest_merged_pr" | jq -r '.merge_commit_sha')
    echo "🔍 Found merged PR #$pr_number with SHA $pr_merge_commit_sha"

    # Fetch workflow runs for this commit
    runs=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/hashicorp/$repo/actions/runs?per_page=10")

    if ! echo "$runs" | jq . >/dev/null 2>&1; then
        echo "❌ Failed to fetch workflow runs for $repo"
        exit 1
    fi

    runs=$(echo "$runs" | jq --arg sha "$pr_merge_commit_sha" '[.workflow_runs[] | select(.head_sha == $sha and .status == "completed" and .conclusion == "success")]')

    if [[ "$runs" != "null" && $(echo "$runs" | jq length) -gt 0 ]]; then
        run_id=$(echo "$runs" | jq '.[0].id')
        echo "✅ Found successful workflow run ID: $run_id"

        artifacts=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/hashicorp/$repo/actions/runs/$run_id/artifacts")

        if ! echo "$artifacts" | jq . >/dev/null 2>&1; then
            echo "❌ Failed to fetch artifacts for run $run_id"
            exit 1
        fi

        artifact_url=$(echo "$artifacts" \
            | jq -r '.artifacts[] | select(.name | test("(?i)^coverage-report")) | .archive_download_url' \
            | head -n1)

        if [[ -n "$artifact_url" && "$artifact_url" != "null" ]]; then
            echo "📦 Downloading coverage artifact..."
            tmpdir=$(mktemp -d)
            curl -sL -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                -H "Accept: application/vnd.github.v3+json" \
                "$artifact_url" -o "$tmpdir/artifact.zip"

            unzip -q "$tmpdir/artifact.zip" -d "$tmpdir"

            coverage_file=$(find "$tmpdir" -type f -name "coverage.out" | head -n1)

            if [[ -f "$coverage_file" ]]; then
                echo "📁 Found coverage file: $coverage_file"

                # Option A: go tool cover (best if it works)
                pushd "$(mktemp -d)" >/dev/null
                go mod init dummy >/dev/null 2>&1
                coverage_output=$(go tool cover -func="$coverage_file" 2>/dev/null | grep total | awk '{print $3}')
                popd >/dev/null

                # Option B: fallback to grep if needed
                if [[ -z "$coverage_output" ]]; then
                    echo "⚠️  go tool cover failed, falling back to grep"
                    coverage_output=$(grep total "$coverage_file" | awk '{print $3}')
                fi

                test_coverage="${coverage_output:-"--"}"
            else
                echo "❌ No coverage.out file found in artifact"
            fi

            rm -rf "$tmpdir"
        else
            echo "❌ No coverage-report artifact found"
        fi
    else
        echo "❌ No matching successful workflow run for commit $pr_merge_commit_sha"
    fi
else
    echo "❌ No merged PR found for $repo"
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