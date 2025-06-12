#!/bin/bash
set -e

NUM_JOBS=10  # Number of parallel jobs

# Ensure repo file exists
if [[ ! -f "$REPO_FILE" ]]; then
    echo "Repository file '$REPO_FILE' not found!"
    exit 1
fi

PREV_FILE="/tmp/prev_metrics.json"
cp "$OUTPUT_FILE" "$PREV_FILE" 2>/dev/null || true
export PREV_FILE

fetch_metrics() {
    repo=$1

    # Fetch repository details (includes open_issues_count)
    response=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                     -H "Accept: application/vnd.github.v3+json" \
                     "https://api.github.com/repos/hashicorp/$repo")

    # Validate response
    if [[ -z "$response" || "$response" == "null" ]]; then
        echo "{\"repo\":\"$repo\",\"forked_from\":\"--\",\"open_issues\":0,\"open_prs\":0,\"triggered_on_push_or_pr\":false,\"release_version\":\"--\",\"tag\":\"--\",\"test_coverage\":\"--\"}"
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

                # if echo "$yaml_content" | yq eval -e '
                #  (
                #     (.on == "push") or
                #     (.on == "pull_request") or
                #     ( (.on | type == "!!seq") and (.on[] == "push" or .on[] == "pull_request") ) or
                #     ( (.on | type == "!!map") and (has("push") or has("pull_request")) )
                #  )
                # ' - >/dev/null 2>&1; then
                #     triggered_on_push_or_pr=true
                #     break
                # fi

                # Check if the workflow triggers on push or pull_request

                if echo "$yaml_content" | grep -E '^\s*on:\s*$' >/dev/null || \
                   echo "$yaml_content" | grep -E '^\s*on:\s*(push|pull_request|\[.*(push|pull_request).*\])' >/dev/null; then
                    triggered_on_push_or_pr=true
                    break
                fi
            done
        fi
    fi

    # Get Unit Test Coverage Percentage
    test_coverage="--"
    if [[ "$repo" == "mql" ]]; then
        content=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                         -H "Accept: application/vnd.github.v3+json" \
                         "https://api.github.com/repos/hashicorp/$repo/contents/coverage?ref=main" \
                         | jq -r '.[] | select(.name == "coverage.log") | .download_url')
        
        if [[ -n "$content" && "$content" != "null" ]]; then
            test_coverage="$(curl -s "$content" | tail -n 1 | cut -d',' -f2)%"
        fi
    else
        if [[ "$repo" == "go-plugin" || "$repo" == "go-version" ]]; then
            pr=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                        -H "Accept: application/vnd.github.v3+json" \
                        "https://api.github.com/repos/hashicorp/$repo/pulls?state=closed&direction=desc")
        else
           pr=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                        -H "Accept: application/vnd.github.v3+json" \
                        "https://api.github.com/repos/hashicorp/$repo/pulls?state=closed&sort=updated&direction=desc")
                                    
        fi

        if [[ -n "$pr" && "$pr" != "null" ]]; then
            latest_merged_pr=$(echo "$pr" | jq '[.[] | select(.merged_at != null and .user.login != "dependabot[bot]" and .merged_by.login != "dependabot[bot]")][0]')
        fi

        if [[ -n "$latest_merged_pr" && "$latest_merged_pr" != "null" ]]; then
            head_sha=$(echo "$latest_merged_pr" | jq -r '.head.sha // empty')
            pr_merge_commit_sha=$(echo "$latest_merged_pr" | jq -r '.merged_commit_sha // empty')

            for sha in "$head_sha" "$pr_merge_commit_sha"; do
                [[ -z "$sha" ]] && continue

                page_no=1
                artifact_found=false
                while [[ "$artifact_found" == false ]]; do
                   res=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                                -H "Accept: application/vnd.github.v3+json" \
                                "https://api.github.com/repos/hashicorp/$repo/actions/runs?per_page=100&page=$page_no")
                   run_ids=$(echo "$res" | jq -r --arg sha "$sha" '[.workflow_runs[] | select(.head_sha == $sha and .status == "completed" and (.event == "push" or .event == "pull_request"))] | .[].id')
                   for run_id in $run_ids; do
                       artifact_url=$(curl -s -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                                            -H "Accept: application/vnd.github.v3+json" \
                                            "https://api.github.com/repos/hashicorp/$repo/actions/runs/$run_id/artifacts" \
                                            | jq -e -r '.artifacts[] | select(.name | test("(?i)^(coverage-report|linux-test-results)")) | .archive_download_url' \
                                            | head -n1)

                       if [[ -n "$artifact_url" ]]; then
                           tmpdir=$(mktemp -d)
                           curl -s -L -H "Authorization: Bearer $GITHUB_APP_TOKEN" \
                                 -H "Accept: application/vnd.github.v3+json" \
                                 "$artifact_url" -o "$tmpdir/artifact.zip"
                           if ! unzip -q "$tmpdir/artifact.zip" -d "$tmpdir" 2> "$tmpdir/unzip_error.log"; then
                              if grep -q "End-of-central-directory signature not found" "$tmpdir/unzip_error.log"; then
                                  if [[ "$test_coverage" == "--" ]]; then
                                      prev_coverage="--"
                                      metrics_file="$PREV_FILE"
                                      if [[ -f "$metrics_file" ]]; then
                                          prev_coverage=$(jq -r --arg repo "$repo" '.[] | select(.repo == $repo) | .test_coverage // "--"' "$metrics_file")
                                      fi
                                      prev_coverage_cleaned=$(echo "$prev_coverage" | sed 's/ *//')
                                      if [[ "$prev_coverage_cleaned" != "--" && "$prev_coverage_cleaned" != "null" && -n "$prev_coverage_cleaned" ]]; then
                                          test_coverage="${prev_coverage_cleaned} *"
                                      fi
                                  fi
                                  rm -rf "$tmpdir"
                              fi
                              rm -rf "$tmpdir"
                           else
                              coverage_file=$(find "$tmpdir" -type f \( -name "coverage.out" -o -name "coverage-*.out" -o -name "linux_cov.part" \) | head -n1)
                              if [[ -f "$coverage_file" ]]; then
                                  total=0
                                  covered=0
                                  while read -r line; do
                                      stmts=$(echo "$line" | awk '{print $2}')
                                      hits=$(echo "$line" | awk '{print $3}')
                                      total=$((total + stmts))
                                      if [[ "$hits" -gt 0 ]]; then
                                          covered=$((covered + stmts))
                                      fi
                                  done < "$coverage_file"

                                  if [[ "$total" -gt 0 ]]; then
                                      test_coverage=$(awk "BEGIN { printf \"%.1f%%\", ($covered/$total)*100 }")
                                      rm -rf "$tmpdir"
                                      break 2
                                  fi
                              fi
                          fi
                          rm -rf "$tmpdir"
                          break
                       fi
                  done

                  if [[ "$artifact_found" == false && $(echo "$res" | jq '.workflow_runs | length') -lt 100 ]]; then
                      break
                  fi
                  ((page++))
              done
           done
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

    echo "{\"repo\":\"$repo\",\"forked_from\":\"$forked_from\",\"open_issues\":$actual_issues,\"open_prs\":$pr_count,\"triggered_on_push_or_pr\":$triggered_on_push_or_pr,\"release_version\":\"$release_version\",\"tag\":\"$tag\",\"test_coverage\":\"$test_coverage\"}"
}

export -f fetch_metrics

# Use xargs for parallel execution
cat "$REPO_FILE" | xargs -I{} -P $NUM_JOBS bash -c 'fetch_metrics "$@"' _ {} | jq --slurp . - > "$OUTPUT_FILE"

echo "Metrics saved to $OUTPUT_FILE"