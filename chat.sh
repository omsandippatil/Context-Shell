#!/bin/bash
 
# Configuration
GROQ_API_KEY="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"
MINDMAP_FILE="mindmap.json"
MODEL="llama3-70b-8192"
DATE=$(date +"%Y-%m-%d")
 
for cmd in curl jq; do
    if ! command -v $cmd &>/dev/null; then
        echo "Error: $cmd is required but not installed. Please install it and try again."
        exit 1
    fi
done
 
initialize_mindmap() {
    if [ ! -f "$MINDMAP_FILE" ]; then
        echo '{
            "entities": {
                "person": {},
                "place": {},
                "organization": {},
                "event": {},
                "object": {},
                "concept": {},
                "conversation": {}
            },
            "conversations": {}
        }' | jq '.' > "$MINDMAP_FILE"
        echo "Created new mindmap file: $MINDMAP_FILE"
    fi
}
 
escape_json() {
    echo "$1" | jq -Rs '.'
}
 
call_groq() {
    local prompt="$1"
    local system_message="$2"
    local max_retries=3
    local retry_count=0
    local response=""
     
    local payload=$(jq -n \
        --arg model "$MODEL" \
        --arg system "$system_message" \
        --arg user "$prompt" \
        '{
            "model": $model,
            "temperature": 0.7,
            "messages": [
                {"role": "system", "content": $system},
                {"role": "user", "content": $user}
            ]
        }')
 
    while [ $retry_count -lt $max_retries ]; do
        response=$(curl -s -X POST "https://api.groq.com/openai/v1/chat/completions" \
            -H "Authorization: Bearer $GROQ_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$payload")
         
        if echo "$response" | jq -e '.choices[0].message.content' &>/dev/null; then 
            echo "$response" | jq -r '.choices[0].message.content'
            return 0
        else
            retry_count=$((retry_count + 1))
            echo "API call failed (attempt $retry_count/$max_retries). Retrying..." >&2
            sleep 1
        fi
    done
    
    echo "Error: Failed to get response after $max_retries attempts"
    return 1
}

# Extract entities and details
extract_entities() {
    local text="$1"
    
    local system_prompt="Extract key entities and details from this text and organize them into a structured mindmap.

Format your response STRICTLY as a valid JSON with two main sections:
1. 'entities': Categorize entities by type (person, place, organization, event, object, concept, conversation)
2. 'metadata': Include conversation date and summary

For each entity, extract:
- 'relationships': connections to other entities
- 'attributes': key characteristics
- 'experiences': interactions or events involving the entity
- 'memories': historical context related to the entity

EXAMPLE OUTPUT FORMAT:
{
  \"entities\": {
    \"person\": {
      \"John\": {
        \"relationships\": {\"Mary\": \"colleague\", \"Acme Inc\": \"employer\"},
        \"attributes\": {\"role\": \"project manager\", \"expertise\": \"data science\"},
        \"experiences\": {\"project_alpha\": \"leading development\"},
        \"memories\": {\"joined_company\": \"2023-05-15\"}
      }
    },
    \"organization\": {
      \"Acme Inc\": {
        \"relationships\": {\"John\": \"employee\", \"Mary\": \"employee\"},
        \"attributes\": {\"industry\": \"technology\", \"size\": \"medium\"},
        \"experiences\": {\"project_alpha\": \"current major project\"},
        \"memories\": {\"founded\": \"2010\"}
      }
    },
    \"conversation\": {
      \"Project Status Update\": {
        \"relationships\": {\"John\": \"participant\", \"Mary\": \"participant\"},
        \"attributes\": {\"topic\": \"project timeline\", \"outcome\": \"deadline extended\"},
        \"experiences\": {},
        \"memories\": {\"previous_meeting\": \"2025-03-27\"}
      }
    },
    \"object\": {
      \"Project Report\": {
        \"relationships\": {\"John\": \"author\", \"Acme Inc\": \"owner\"},
        \"attributes\": {\"format\": \"PDF\", \"length\": \"42 pages\"},
        \"experiences\": {},
        \"memories\": {\"last_updated\": \"2025-04-01\"}
      }
    }
  },
  \"metadata\": {
    \"date\": \"2025-04-03\",
    \"summary\": \"Discussion about Project Alpha progress at Acme Inc\"
  }
}

IMPORTANT: Output ONLY the JSON with no additional text, explanation, or formatting. Ensure all existing entity data is preserved and enriched, not overwritten."
    
    # Call Groq for extraction
    local extraction=$(call_groq "$text" "$system_prompt")
    
    # Ensure we have valid JSON output
    if echo "$extraction" | jq empty &>/dev/null; then
        echo "$extraction"
    else
        # Try to fix common JSON parsing issues
        local fixed_json=$(echo "$extraction" | sed 's/```json//g' | sed 's/```//g' | sed 's/^```$//g')
        if echo "$fixed_json" | jq empty &>/dev/null; then
            echo "$fixed_json"
        else
            echo "Warning: Received invalid JSON from extraction process" >&2
            echo '{"entities":{},"metadata":{"date":"","summary":""}}'
        fi
    fi
}

# Update mindmap
update_mindmap() {
    local user_input="$1"
    local bot_response="$2"
    local extraction="$3"
    local current_date=$(date +"%Y-%m-%d")
    
    # Create backup of current mindmap
    cp "$MINDMAP_FILE" "${MINDMAP_FILE}.bak"
    
    # Validate extraction JSON
    if ! echo "$extraction" | jq empty &>/dev/null; then
        echo "Warning: Received invalid JSON from extraction process" >&2
        extraction='{"entities":{},"metadata":{"date":"'"$current_date"'","summary":""}}'
    fi
    
    # Extract metadata
    local conversation_date=$(echo "$extraction" | jq -r '.metadata.date // "'"$current_date"'"')
    local summary=$(echo "$extraction" | jq -r '.metadata.summary // ""')
    
    # Parse conversation timestamp
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    # Create a temporary file for the jq script
    local temp_jq_script=$(mktemp)
    
    # Write the jq script to the temporary file
    cat > "$temp_jq_script" << 'EOF'
# Function to merge arrays by combining unique elements
def merge_arrays(a; b):
  if (a | type) == "array" and (b | type) == "array" then
    a + b | unique
  else
    b
  end;

# Function to recursively merge objects by combining values
def deep_merge(a; b):
  if (a | type) == "object" and (b | type) == "object" then
    # Create a new object with keys from both inputs
    a as $a | b as $b | reduce (($a | keys) + ($b | keys) | unique[]) as $k
      ({}; 
        # If key exists in both, merge the values
        if ($a[$k] != null) and ($b[$k] != null) then
          if ($a[$k] | type) == "object" and ($b[$k] | type) == "object" then
            .[$k] = deep_merge($a[$k]; $b[$k])
          elif ($a[$k] | type) == "array" and ($b[$k] | type) == "array" then
            .[$k] = merge_arrays($a[$k]; $b[$k])
          else
            .[$k] = $b[$k]  # Prefer new value
          end
        # If key exists only in one, use that value
        elif $a[$k] != null then
          .[$k] = $a[$k]
        else
          .[$k] = $b[$k]
        end
      )
  else
    b  # If not both objects, prefer the new value
  end;

# Main update logic
. as $original |
$extraction.entities as $new_entities |

# Initialize entities categories if they don't exist
. = (
  if has("entities") then
    .
  else
    . + {"entities": {
      "person": {},
      "place": {},
      "organization": {},
      "event": {},
      "object": {},
      "concept": {},
      "conversation": {}
    }}
  end
) |

# Merge entities
($new_entities | keys) as $entity_types |
reduce $entity_types[] as $type
  (.;
    if ($original.entities[$type] != null) then
      .entities[$type] = deep_merge($original.entities[$type]; $new_entities[$type])
    else
      .entities[$type] = $new_entities[$type]
    end
  ) |

# Update conversations by date
if .conversations[$date] then
  .conversations[$date].exchanges += [{
    "timestamp": $timestamp,
    "user": $user,
    "assistant": $assistant
  }] |
  if $summary != "" then
    .conversations[$date].summary = $summary
  else
    .
  end
else
  .conversations[$date] = {
    "summary": $summary,
    "exchanges": [{
      "timestamp": $timestamp,
      "user": $user,
      "assistant": $assistant
    }]
  }
end
EOF

    # Update mindmap using the temporary jq script
    jq --from-file "$temp_jq_script" \
       --argjson extraction "$extraction" \
       --arg timestamp "$timestamp" \
       --arg date "$conversation_date" \
       --arg summary "$summary" \
       --arg user "$user_input" \
       --arg assistant "$bot_response" \
       "${MINDMAP_FILE}.bak" > "$MINDMAP_FILE"
    
    # Remove the temporary script
    rm "$temp_jq_script"
    
    # Check if operation was successful
    if [ $? -eq 0 ] && [ -s "$MINDMAP_FILE" ]; then
        # Validate the new mindmap file
        if jq empty "$MINDMAP_FILE" &>/dev/null; then
            echo "Mindmap updated successfully."
            rm "${MINDMAP_FILE}.bak"
        else
            echo "Error: Generated invalid JSON. Restoring backup." >&2
            mv "${MINDMAP_FILE}.bak" "$MINDMAP_FILE"
        fi
    else
        echo "Error: Failed to update mindmap file. Restoring backup." >&2
        mv "${MINDMAP_FILE}.bak" "$MINDMAP_FILE"
    fi
}

# Main function
main() {
    # Initialize mindmap
    initialize_mindmap
    
    # Welcome message
    echo "Mindmap JSON Storage (type 'exit' to quit)"
    echo "Today's date: $DATE"
    echo "Model: $MODEL"
    
    # Main chat loop
    while true; do
        # Get user input
        echo -n "Input: "
        read -r user_input
        
        # Check for exit command
        if [ "$user_input" = "exit" ]; then
            echo "Exiting. Your mindmap has been saved to $MINDMAP_FILE."
            exit 0
        fi
        
        # Skip empty input
        if [ -z "$user_input" ]; then
            continue
        fi
        
        # Get current mindmap state for context
        current_mindmap=$(cat "$MINDMAP_FILE")
        
        # Create system message with current mindmap context
        system_message="You are an AI assistant that stores information in a structured mindmap. Today's date is $DATE.

Your responses should be clear and informative. Respond as if you are having a conversation with the user.

Current mindmap state:
$current_mindmap"
        
        # Get response from Groq
        echo "Processing..."
        bot_response=$(call_groq "$user_input" "$system_message")
        
        # Check if we got a valid response
        if [ -z "$bot_response" ] || [ "$bot_response" = "Error: Failed to get response after 3 attempts" ]; then
            echo "Error: Failed to process request"
            continue
        fi
        
        # Display the response
        echo "Response:"
        echo "$bot_response"
        
        # Extract entities and details
        echo "Updating mindmap..."
        extraction=$(extract_entities "$user_input $bot_response")
        
        # Update mindmap with new information
        update_mindmap "$user_input" "$bot_response" "$extraction"
    done
}

# Run the main function
main