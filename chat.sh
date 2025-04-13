#!/bin/bash

# Configuration
GROQ_API_KEY="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"
MEMORY_FILE="mindmap.json"
LOG_FILE="memory_log.txt"
ERROR_LOG="error_log.txt"
MODEL="llama3-70b-8192"  # Smaller model
MAX_TOKENS=8000  # Higher token limit
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# Dependency checks
for cmd in curl jq; do
    command -v $cmd &>/dev/null || { echo "Missing required: $cmd" | tee -a "$ERROR_LOG"; exit 1; }
done

# Log function for tracking input/output
log_activity() {
    local input_length=${1:-0}
    local output_length=${2:-0}
    local status="$3"
    
    echo "[$TIMESTAMP] Input chars: $input_length | Output chars: $output_length | Status: $status" >> "$LOG_FILE"
}

# Log errors
log_error() {
    local message="$1"
    echo "[$TIMESTAMP] ERROR: $message" >> "$ERROR_LOG"
    echo "Error: $message"
}

# Initialize JSON structure
initialize_memory() {
    if [ ! -f "$MEMORY_FILE" ]; then
        echo '{
            "entities": {
                "people": {},
                "places": {},
                "events": {},
                "objects": {},
                "concepts": {}
            },
            "raw_history": [],
            "_metadata": {
                "created": "'"$TIMESTAMP"'",
                "last_updated": "'"$TIMESTAMP"'"
            }
        }' | jq . > "$MEMORY_FILE"
        
        echo "[$TIMESTAMP] Created new memory file" >> "$LOG_FILE"
    fi
}

# Enhanced API call with validation
call_groq() {
    local prompt="$1"
    local input_length=${#prompt}
    local response
    
    response=$(curl -s -X POST "https://api.groq.com/openai/v1/chat/completions" \
        -H "Authorization: Bearer $GROQ_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg model "$MODEL" \
            --arg prompt "$prompt" \
            --argjson max_tokens $MAX_TOKENS \
            '{
                "model": $model,
                "temperature": 0.3,
                "max_tokens": $max_tokens,
                "response_format": {"type": "json_object"},
                "messages": [
                    {
                        "role": "system", 
                        "content": "Output STRICT VALID JSON with exact detail preservation. Record EVERY word and detail in appropriate entities. Never summarize or omit information."
                    },
                    {"role": "user", "content": $prompt}
                ]
            }')")
    
    local output_content=$(echo "$response" | jq -r '.choices[0].message.content // empty')
    local output_length=${#output_content}
    
    if [[ -z "$output_content" ]]; then
        log_error "Empty response from API"
        log_activity "$input_length" 0 "FAILED"
        echo "$response" >> "$ERROR_LOG"
        return 1
    fi
    
    if ! jq -e . <<<"$output_content" &>/dev/null; then
        log_error "Invalid JSON response"
        log_activity "$input_length" "$output_length" "INVALID_JSON"
        echo "$output_content" >> "$ERROR_LOG"
        return 1
    fi
    
    log_activity "$input_length" "$output_length" "SUCCESS"
    echo "$output_content"
    return 0
}

# Optimized detailed information extraction
extract_information() {
    local text="$1"
    cat <<EOF
Return JSON with EXACT structure:

{
  "entities": {
    "people": {
      "[NAME]": {
        "attributes": {/* ALL mentioned traits, words, and details */},
        "memory": [{
          "timestamp": "$TIMESTAMP",
          "content": "[VERBATIM_DETAIL]",
          "context": "[RELATED_ENTITIES]"
        }]
    }},
    "places": { /* Similar structure with EVERY detail */ },
    "events": { /* Similar structure with EVERY detail */ },
    "objects": { /* Similar structure with EVERY detail */ },
    "concepts": { /* Similar structure with EVERY detail */ }
  }
}

RULES:
1. Record EVERY single word, detail, and nuance mentioned
2. Do not summarize or condense information
3. Create entities for EVERY named or implied item
4. Split complex descriptions into multiple detailed attributes
5. Preserve exact quoted text when possible
6. Record even seemingly trivial details

Input:
$text
EOF
}

# Memory update with detailed preservation
update_memory() {
    local new_data="$1"
    local raw_input="$2"
    
    # Read the current file
    local current_data=$(cat "$MEMORY_FILE")
    
    # Update the memory file with merged data
    jq --argjson new "$new_data" --arg raw "$raw_input" --arg ts "$TIMESTAMP" '
    # Recursive merge with enhanced detail preservation
    def deep_merge(a; b):
        a as $a | b as $b |
        if ($a|type) == "object" and ($b|type) == "object" then
            reduce ($b|keys[]) as $key (
                $a;
                .[$key] = if $a[$key] == null then $b[$key]
                         elif ($a[$key]|type) == "object" and ($b[$key]|type) == "object" then 
                             deep_merge($a[$key]; $b[$key])
                         elif ($a[$key]|type) == "array" and ($b[$key]|type) == "array" then
                             $a[$key] + $b[$key]
                         else
                             $b[$key] // $a[$key]
                         end
            )
        else
            $b
        end;
    
    # Update metadata timestamp
    ._metadata.last_updated = $ts |
    
    # Add raw input to history with timestamp
    .raw_history += [{
        "timestamp": $ts,
        "input": $raw
    }] |
    
    # Merge entities with complete detail preservation
    .entities |= deep_merge(.; $new.entities)
    ' <<<"$current_data" > "${MEMORY_FILE}.tmp"
    
    # Verify the new JSON is valid before replacing
    if jq empty "${MEMORY_FILE}.tmp" 2>/dev/null; then
        mv "${MEMORY_FILE}.tmp" "$MEMORY_FILE"
        echo "Memory updated successfully"
    else
        log_error "Failed to update memory - invalid JSON generated"
        rm "${MEMORY_FILE}.tmp"
        return 1
    fi
}

# Main function simplified to just add data
main() {
    initialize_memory
    echo "Detailed Memory Recording System"
    echo "Enter your data (type 'exit' to quit):"
    
    while true; do
        echo -n "> "
        read -r user_input
        
        if [[ "$user_input" == "exit" ]]; then
            break
        fi
        
        if [[ -z "$user_input" ]]; then
            echo "Input cannot be empty"
            continue
        fi
        
        echo "Processing details..."
        extraction_prompt=$(extract_information "$user_input")
        
        if structured_data=$(call_groq "$extraction_prompt"); then
            echo "Preserving all details in memory..."
            if update_memory "$structured_data" "$user_input"; then
                echo "Added to mindmap.json"
            else
                echo "Failed to update memory file"
            fi
        else
            echo "Failed to process input"
        fi
    done
}

# Create log files if they don't exist
touch "$LOG_FILE" "$ERROR_LOG"

# Run main function
main