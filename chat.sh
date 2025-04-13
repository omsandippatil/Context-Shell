#!/bin/bash

# Configuration
GROQ_API_KEY="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"
MEMORY_FILE="memory.json"
MODEL="llama3-70b-8192"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# Dependency checks
for cmd in curl jq flock; do
    command -v $cmd &>/dev/null || { echo "Missing required: $cmd"; exit 1; }
done

# Initialize JSON structure with proper locking
initialize_memory() {
    (
        flock 200
        [ -f "$MEMORY_FILE" ] || echo '{
            "entities": {
                "people": {},
                "places": {},
                "events": {},
                "objects": {},
                "concepts": {}
            },
            "temporal_records": [],
            "raw_history": [],
            "_metadata": {
                "created": "'"$TIMESTAMP"'",
                "last_updated": "'"$TIMESTAMP"'"
            }
        }' | jq . > "$MEMORY_FILE"
    ) 200>"${MEMORY_FILE}.lock"
}

# Atomic JSON save with robust error recovery
safe_save() {
    local temp_file=$(mktemp)
    local backup_file="${MEMORY_FILE}.bak.$(date +%s)"
    
    # Create backup
    cp "$MEMORY_FILE" "$backup_file"
    
    # Process and validate
    if jq . > "$temp_file" 2>/dev/null; then
        # Verify JSON validity before replacing
        if jq empty "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$MEMORY_FILE"
            echo "Update successful"
        else
            echo "Invalid JSON generated, restoring backup"
            mv "$backup_file" "$MEMORY_FILE"
            return 1
        fi
    else
        echo "JSON processing failed, restoring backup"
        mv "$backup_file" "$MEMORY_FILE"
        return 1
    fi
    
    # Keep last 10 backups for better recovery options
    ls -t "${MEMORY_FILE}.bak."* | tail -n +11 | xargs rm -f --
}

# Enhanced API call with validation and retry logic
call_groq() {
    local prompt="$1"
    local max_retries=3
    local retry_count=0
    local response
    
    while [ $retry_count -lt $max_retries ]; do
        response=$(curl -s -X POST "https://api.groq.com/openai/v1/chat/completions" \
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
                            "content": "Output STRICT VALID JSON. Preserve ALL details with exact timestamps."
                        },
                        {"role": "user", "content": $prompt}
                    ]
                }')" | jq -r '.choices[0].message.content')
        
        if jq -e . <<<"$response" &>/dev/null; then
            echo "$response"
            return 0
        else
            retry_count=$((retry_count + 1))
            echo "Invalid JSON response (attempt $retry_count/$max_retries)" >&2
            sleep 1
        fi
    done
    
    echo "Error: Maximum retries reached" >&2
    return 1
}

# Optimized structured data extraction with full context preservation
extract_information() {
    local text="$1"
    cat <<EOF
Return JSON with EXACT structure:

{
  "entities": {
    "people": {
      "[NAME]": {
        "attributes": {/* All mentioned traits */},
        "memory": [{
          "timestamp": "$TIMESTAMP",
          "content": "[VERBATIM_DETAIL]",
          "context": "[RELATED_ENTITIES]"
        }]
    }},
    "places": { /* Similar structure */ },
    "events": { /* Similar structure */ },
    "objects": { /* Similar structure */ },
    "concepts": { /* Similar structure */ }
  },
  "temporal_records": [{
    "timestamp": "$TIMESTAMP",
    "entity_type": "[TYPE]",
    "entity_name": "[NAME]",
    "memory_fragment": "[DETAIL]",
    "full_context": "[COMPLETE_INPUT]"
  }]
}

RULES:
1. Preserve original text exactly in both entity memories and temporal records
2. Include full entry context in temporal_records.full_context
3. Never omit details or truncate content
4. Ensure consistent timestamp format across all entries

Input:
$text
EOF
}

# Thread-safe memory update with raw history preservation
update_memory() {
    local new_data="$1"
    local raw_input="$2"
    
    (
        flock 200
        jq --argjson new "$new_data" --arg raw "$raw_input" --arg ts "$TIMESTAMP" '
        # Recursive merge with deduplication
        def deep_merge(a; b):
            a as $a | b as $b |
            if ($a|type) == "object" and ($b|type) == "object" then
                reduce ($b|keys[]) as $key (
                    $a;
                    .[$key] = if $a[$key] == null then $b[$key]
                             else deep_merge($a[$key]; $b[$key])
                             end
                )
            elif ($a|type) == "array" and ($b|type) == "array" then
                ($a + $b) | unique_by(.timestamp + .content)
            else
                $b // $a
            end;
        
        # Update metadata
        ._metadata.last_updated = $ts |
        
        # Add raw input to history with timestamp
        .raw_history += [{
            "timestamp": $ts,
            "input": $raw
        }] |
        
        # Merge entities with deep context preservation
        .entities |= deep_merge(.; $new.entities) |
        
        # Add temporal records with full context
        .temporal_records += $new.temporal_records |
        
        # Ensure chronological order
        .temporal_records |= sort_by(.timestamp) |
        .raw_history |= sort_by(.timestamp)
        ' "$MEMORY_FILE" | safe_save
    ) 200>"${MEMORY_FILE}.lock"
}

# Memory query function
query_memory() {
    local query="$1"
    
    (
        flock -s 200
        jq -c --arg q "$query" '
        .entities as $e |
        .temporal_records as $t |
        .raw_history as $r |
        {
            "query": $q,
            "timestamp": "'"$TIMESTAMP"'",
            "matches": {
                "entities": [
                    # Search through entities
                    ($e.people | to_entries[] | select(.key | test($q;"i")) | 
                        {type: "person", name: .key, data: .value}),
                    ($e.places | to_entries[] | select(.key | test($q;"i")) | 
                        {type: "place", name: .key, data: .value}),
                    ($e.events | to_entries[] | select(.key | test($q;"i")) | 
                        {type: "event", name: .key, data: .value}),
                    ($e.objects | to_entries[] | select(.key | test($q;"i")) | 
                        {type: "object", name: .key, data: .value}),
                    ($e.concepts | to_entries[] | select(.key | test($q;"i")) | 
                        {type: "concept", name: .key, data: .value})
                ],
                "temporal": [
                    # Search through temporal records
                    $t[] | select(.full_context | test($q;"i"))
                ],
                "raw_history": [
                    # Search through raw history
                    $r[] | select(.input | test($q;"i"))
                ]
            }
        }' "$MEMORY_FILE"
    ) 200>"${MEMORY_FILE}.lock"
}

# Function to restore from backup
restore_from_backup() {
    local backup_list=$(ls -t "${MEMORY_FILE}.bak."* 2>/dev/null)
    
    if [ -z "$backup_list" ]; then
        echo "No backups found"
        return 1
    fi
    
    echo "Available backups:"
    local i=1
    while read -r backup; do
        local date_str=$(date -r "$backup" "+%Y-%m-%d %H:%M:%S")
        echo "$i) $date_str - $backup"
        i=$((i+1))
    done <<< "$backup_list"
    
    echo -n "Select backup to restore (number): "
    read -r selection
    
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        local selected_backup=$(echo "$backup_list" | sed -n "${selection}p")
        if [ -f "$selected_backup" ]; then
            cp "$MEMORY_FILE" "${MEMORY_FILE}.before_restore.$(date +%s)"
            cp "$selected_backup" "$MEMORY_FILE"
            echo "Restored from: $selected_backup"
            return 0
        fi
    fi
    
    echo "Invalid selection or backup not found"
    return 1
}

# Main function with expanded capabilities
main() {
    initialize_memory
    echo "Enhanced Journal Memory System - Full Context Preservation"
    
    while true; do
        echo -n "Command (add/query/backup/restore/exit): "
        read -r command
        
        case "$command" in
            add|a)
                echo -n "Entry: "
                read -r user_input
                
                echo "Processing..."
                extraction_prompt=$(extract_information "$user_input")
                if structured_data=$(call_groq "$extraction_prompt"); then
                    echo "Validating structure..."
                    if jq -e . <<<"$structured_data" &>/dev/null; then
                        echo "Updating memory with full context..."
                        update_memory "$structured_data" "$user_input"
                    else
                        echo "Invalid structure: $structured_data"
                    fi
                else
                    echo "Failed to process input"
                fi
                ;;
                
            query|q)
                echo -n "Search term: "
                read -r search_term
                query_result=$(query_memory "$search_term")
                echo "$query_result" | jq '.'
                ;;
                
            backup|b)
                cp "$MEMORY_FILE" "${MEMORY_FILE}.manual.$(date +%s)"
                echo "Manual backup created"
                ;;
                
            restore|r)
                restore_from_backup
                ;;
                
            exit|e)
                break
                ;;
                
            *)
                echo "Unknown command: $command"
                echo "Available commands: add/a, query/q, backup/b, restore/r, exit/e"
                ;;
        esac
    done
}

main