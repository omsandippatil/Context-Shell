#!/bin/bash

# Configuration
GROQ_API_KEY="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"
MINDMAP_FILE="mindmap.json"
MODEL="llama3-70b-8192"
DATE=$(date +"%Y-%m-%d")

# Check for required commands
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
                "object": {}
            },
            "conversations_by_date": {},
            "facts": {},
            "logs": []
        }' | jq '.' > "$MINDMAP_FILE"
        echo "Created new mindmap file: $MINDMAP_FILE"
    fi
}

escape_json() {
    echo "$1" | jq -Rs '.'
}

call_groq() {
    local prompt="$1"
    local max_retries=3
    local retry_count=0
    local response=""
    
    local payload=$(jq -n \
        --arg model "$MODEL" \
        --arg user "$prompt" \
        '{
            "model": $model,
            "temperature": 0.7,
            "response_format": {"type": "json_object"},
            "messages": [
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
    local extract_prompt="Extract key entities and details from this text and organize them into a structured mindmap. Today's date is $DATE. Format your response STRICTLY as a valid JSON with the following structure:

{
  \"entities\": {
    \"person\": {
      \"[PersonName]\": {
        \"relationships\": {
          \"[RelatedEntityName]\": {
            \"type\": \"[RelationshipType]\",
            \"details\": \"[Optional details]\"
          }
        },
        \"attributes\": {\"[AttributeName]\": \"[AttributeValue]\"},
        \"conversations\": [
          {
            \"date\": \"YYYY-MM-DD\",
            \"time\": \"HH:MM:SS\",
            \"dialogue\": [
              {\"speaker\": \"[Speaker]\", \"text\": \"[Text]\"}
            ],
            \"topics\": [\"[Topic1]\", \"[Topic2]\"],
            \"sentiment\": \"[positive/negative/neutral]\",
            \"location\": \"[Location]\",
            \"context\": \"[Context of conversation]\",
            \"key_points\": [\"[KeyPoint1]\", \"[KeyPoint2]\"],
            \"summary\": \"[Detailed conversation summary]\"
          }
        ]
      }
    },
    \"place\": {
      \"[PlaceName]\": {
        \"memories\": [
          {
            \"date\": \"YYYY-MM-DD HH:MM:SS\",
            \"event\": \"[EventName]\",
            \"details\": \"[EventDetails]\"
          }
        ],
        \"attributes\": {\"[AttributeName]\": \"[AttributeValue]\"}
      }
    },
    \"event\": {
      \"[EventName]\": {
        \"date\": \"YYYY-MM-DD HH:MM:SS\",
        \"participants\": [\"[PersonName]\"],
        \"location\": \"[PlaceName]\",
        \"details\": \"[EventDetails]\"}
    },
    \"object\": {
      \"[ObjectName]\": {
        \"category\": \"[Category]\",
        \"attributes\": {\"[AttributeName]\": \"[AttributeValue]\"},
        \"facts\": [\"[Fact1]\", \"[Fact2]\"]
      }
    }
  },
  \"conversations_by_date\": {
    \"YYYY-MM-DD\": {
      \"people\": [\"[PersonName]\"],
      \"conversations\": [
        {
          \"time\": \"HH:MM:SS\",
          \"dialogue\": [
            {\"speaker\": \"[Speaker]\", \"text\": \"[Text]\"}
          ],
          \"summary\": \"[Summary]\"
        }
      ]
    }
  },
  \"facts\": {
    \"[FactID]\": {
      \"statement\": \"[FactStatement]\",
      \"related_entities\": [\"[EntityName]\"],
      \"source\": \"[Source]\",
      \"date_recorded\": \"YYYY-MM-DD HH:MM:SS\"
    }
  },
  \"metadata\": {
    \"date\": \"YYYY-MM-DD\",
    \"summary\": \"[ConversationSummary]\"
  }
}

IMPORTANT: 
1. Output ONLY JSON
2. Include detailed timestamps in YYYY-MM-DD HH:MM:SS format
3. Store conversations both in person entities AND grouped by date 
4. For objects, always include a 'category' field with values like 'movie', 'series', 'book', 'clothing', 'food', etc.
5. Structure all data within the appropriate entity
6. Do not create subcategories
7. Include extremely rich and comprehensive details for all entities
8. Only include data that is explicitly mentioned in the text
9. Do not assign any type of IDs to facts or other elements
10. Store conversations in great detail with full context, topics, sentiment, and comprehensive summaries"

    # Call Groq for extraction with json_object format
    call_groq "$extract_prompt

Text to extract from:
$text"
}

# Update mindmap
update_mindmap() {
    local user_input="$1"
    local bot_response="$2"
    local extraction="$3"
    local current_date=$(date +"%Y-%m-%d")
    local current_time=$(date +"%H:%M:%S")
    
    # Create backup of current mindmap
    cp "$MINDMAP_FILE" "${MINDMAP_FILE}.bak"
    
    # Validate extraction JSON
    if ! echo "$extraction" | jq empty &>/dev/null; then
        echo "Warning: Received invalid JSON from extraction process" >&2
        extraction='{
            "entities": {},
            "conversations_by_date": {},
            "facts": {},
            "metadata": {"date": "'"$current_date"'", "summary": ""}
        }'
    fi
    
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
        a as $a | b as $b | reduce (($a | keys) + ($b | keys) | unique[]) as $k (
            {};
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
. as $original | $extraction as $new_data |

# Initialize entities categories if they don't exist
. = (
    if has("entities") then . 
    else . + {
        "entities": {
            "person": {},
            "place": {},
            "organization": {},
            "event": {},
            "object": {}
        }
    } end
) |

# Initialize conversations_by_date if it doesn't exist
. = (
    if has("conversations_by_date") then .
    else . + {"conversations_by_date": {}} end
) |

# Initialize facts if they don't exist
. = (
    if has("facts") then .
    else . + {"facts": {}} end
) |

# Initialize logs if they don't exist
. = (
    if has("logs") then .
    else . + {"logs": []} end
) |

# Merge entities
($new_data.entities | keys) as $entity_types |
reduce $entity_types[] as $type (.;
    if ($original.entities[$type] != null) then
        .entities[$type] = deep_merge($original.entities[$type]; $new_data.entities[$type])
    else
        .entities[$type] = $new_data.entities[$type]
    end
) |

# Merge conversations by date
if $new_data.conversations_by_date then
    .conversations_by_date = deep_merge($original.conversations_by_date; $new_data.conversations_by_date)
else .
end |

# Merge facts
if $new_data.facts then
    .facts = deep_merge($original.facts; $new_data.facts)
else .
end |

# Add to logs
.logs += [{
    "timestamp": $timestamp,
    "user_input": $user,
    "assistant_response": $assistant
}]
EOF

    # Update mindmap using the temporary jq script
    jq --from-file "$temp_jq_script" \
        --argjson extraction "$extraction" \
        --arg timestamp "$current_date $current_time" \
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
        
        # Create user prompt with instruction to return JSON
        user_prompt="Process this input and respond with a structured JSON reply. Today's date is $DATE. The response must be valid JSON with very detailed entities, attributes, and appropriate categorization. Include category field for objects using values like 'movie', 'series', 'book', 'clothing', etc. Store conversations directly within person entities with rich details including topics, sentiment, and comprehensive summaries.

Input: $user_input"
        
        # Get response from Groq
        echo "Processing..."
        bot_response=$(call_groq "$user_prompt")
        
        # Check if we got a valid response
        if [ -z "$bot_response" ] || [ "$bot_response" = "Error: Failed to get response after 3 attempts" ]; then
            echo "Error: Failed to process request"
            continue
        fi
        
        # Extract entities and details
        echo "Updating mindmap..."
        extraction=$(extract_entities "$user_input $bot_response")
        
        # Update mindmap with new information
        update_mindmap "$user_input" "$bot_response" "$extraction"
    done
}

# Run the main function
main