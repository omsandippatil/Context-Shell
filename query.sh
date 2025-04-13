#!/bin/bash

# Configuration
GROQ_API_KEY="your_api_key_here"
MEMORY_FILE="memory.json"
MODEL="llama3-70b-8192"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# Dependency checks
for cmd in curl jq flock; do
    command -v $cmd &>/dev/null || { echo "Missing required: $cmd"; exit 1; }
done

# Initialize memory if needed
initialize_memory() {
    [ -f "$MEMORY_FILE" ] || echo '{"entities":{},"temporal_records":[],"raw_history":[]}' > "$MEMORY_FILE"
}

# Core query processor
process_question() {
    local question="$1"
    
    # Phase 1: Extract search parameters
    local keywords=$(extract_keywords "$question")
    local time_frame=$(extract_time_frame "$question")
    local entity_types=$(extract_entity_types "$question")
    
    # Phase 2: Fetch relevant context
    local context=$(get_relevant_context "$keywords" "$time_frame" "$entity_types")
    
    # Phase 3: Generate focused answer
    generate_answer "$question" "$context"
}

# Keyword extraction with NLP heuristics
extract_keywords() {
    echo "$1" | \
    tr '[:upper:]' '[:lower:]' | \
    grep -oE '\w{4,}' | \
    grep -vE '^(what|when|where|who|why|how|did|does|do|is|are|was|were)' | \
    sort | uniq
}

# Time frame detection
extract_time_frame() {
    # Detect absolute dates
    local dates=$(echo "$1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    
    # Detect relative time frames
    if [[ "$1" =~ (today|yesterday) ]]; then
        date -d "${BASH_REMATCH[1]}" +"%Y-%m-%d"
    elif [[ "$1" =~ last\s(week|month) ]]; then
        case "${BASH_REMATCH[1]}" in
            week) date -d "1 week ago" +"%Y-%m-%d" ;;
            month) date -d "1 month ago" +"%Y-%m-%d" ;;
        esac
    elif [ -n "$dates" ]; then
        echo "$dates" | head -1
    else
        echo ""
    fi
}

# Entity type detection
extract_entity_types() {
    local types=""
    [[ "$1" =~ (person|people) ]] && types+="person "
    [[ "$1" =~ (place|location) ]] && types+="place "
    [[ "$1" =~ (event|meeting) ]] && types+="event "
    [[ "$1" =~ (object|item) ]] && types+="object "
    [[ "$1" =~ (concept|idea) ]] && types+="concept "
    echo "$types" | xargs
}

# Precision context retrieval with proper jq syntax
get_relevant_context() {
    local keywords=($1)
    local time_frame="$2"
    local entity_types=($3)
    
    # Convert arrays to JSON format for jq
    local kw_json=$(printf '%s\n' "${keywords[@]}" | jq -R . | jq -s .)
    local et_json=$(printf '%s\n' "${entity_types[@]}" | jq -R . | jq -s .)
    
    (
        flock -s 200
        jq --argjson kw "$kw_json" \
           --arg tf "$time_frame" \
           --argjson et "$et_json" '
        def containsAny($str; $terms):
            if ($terms | length) == 0 then true
            else any($terms[]; . != "" and ($str | ascii_downcase | contains(.)))
            end;
        
        def matchesTime($time; $filter):
            $filter == "" or ($time | startswith($filter));
        
        def matchesType($type; $filters):
            ($filters | length) == 0 or ($type != null and ($filters | index($type)));
        
        {
            people: [.entities.people | to_entries[] | 
                select(
                    containsAny(.key; $kw) or 
                    (.value.attributes | tostring | containsAny(.; $kw))
                ) | {
                    name: .key,
                    type: "person",
                    attributes: .value.attributes,
                    memories: [.value.memory[] | 
                        select(
                            containsAny(.content; $kw) and 
                            matchesTime(.timestamp; $tf)
                        ]
                }],
            
            temporal: [.temporal_records[] | 
                select(
                    (containsAny(.entity_name; $kw) or 
                     containsAny(.memory_fragment; $kw) or 
                     containsAny(.full_context; $kw)) and 
                    matchesTime(.timestamp; $tf) and
                    matchesType(.entity_type; $et)
                ) | {
                    timestamp: .timestamp,
                    type: .entity_type,
                    name: .entity_name,
                    content: .memory_fragment,
                    context: .full_context
                }],
            
            concepts: [.entities.concepts | to_entries[] | 
                select(containsAny(.key; $kw)) | {
                    name: .key,
                    type: "concept",
                    description: .value.attributes.description
                }]
        }
        ' "$MEMORY_FILE"
    ) 200>"${MEMORY_FILE}.lock"
}

# Focused answer generation
generate_answer() {
    local question="$1"
    local context="$2"
    
    # Format context for LLM
    local context_str=$(echo "$context" | jq -r '
    def format($items; $prefix):
        if ($items | length) > 0 then
            $items | map("\($prefix) \(.name): \(.content // .description // .attributes)\n" + 
                        (if .memories and (.memories | length) > 0 then 
                            "  Memories:\n    " + (.memories | map("- \(.content) [\(.timestamp)]") | join("\n    ")) 
                         else "" end)) | join("\n")
        else "" end;
    
    ([.people[]] | sort_by(.name)) as $people |
    ([.temporal[]] | sort_by(.timestamp)) as $temporal |
    ([.concepts[]] | sort_by(.name)) as $concepts |
    
    format($people; "Person") + "\n" +
    format($temporal; "Event") + "\n" +
    format($concepts; "Concept")')
    
    # Generate prompt
    local prompt=$(cat <<EOF
Question: $question
Context:
$context_str

Instructions:
1. Answer using ONLY the provided context
2. Never mention "context" or "information" in your answer
3. For temporal questions, use exact timestamps
4. For comparisons, list specific differences
5. Format dates as YYYY-MM-DD
6. Cite sources like [Person: Name] or [Event: YYYY-MM-DD]

Required JSON response format:
{
  "answer": "concise factual answer",
  "sources": ["array of source identifiers"],
  "confidence": "percentage estimate"
}
EOF
    )
    
    # Call Groq API with error handling
    local response
    if ! response=$(curl -s -X POST "https://api.groq.com/openai/v1/chat/completions" \
        -H "Authorization: Bearer $GROQ_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg model "$MODEL" \
            --arg prompt "$prompt" \
            '{
                "model": $model,
                "temperature": 0.3,
                "response_format": {"type": "json_object"},
                "messages": [
                    {
                        "role": "system", 
                        "content": "You are a precise fact retrieval system. Only use provided context."
                    },
                    {"role": "user", "content": $prompt}
                ]
            }')" 2>/dev/null | jq -r '.choices[0].message.content'); then
        echo "Error: Failed to get API response" >&2
        return 1
    fi
    
    # Process response
    if jq -e . <<<"$response" &>/dev/null; then
        echo -e "\nAnswer:"
        echo "$response" | jq -r '.answer'
        echo -e "\nSources:"
        echo "$response" | jq -r '.sources[]' | sed 's/^/- /'
        echo -e "Confidence: $(echo "$response" | jq -r '.confidence')"
    else
        echo "Error processing response. Showing raw context:" >&2
        echo "$context_str"
        return 1
    fi
}

# Main interface
main() {
    initialize_memory
    
    echo "Precision Memory Query System"
    echo "----------------------------"
    
    while true; do
        echo -n "Enter question (or 'exit'): "
        read -r question
        
        [ "$question" = "exit" ] && break
        
        if ! process_question "$question"; then
            echo "Error processing question" >&2
        fi
        echo "----------------------------"
    done
}

main