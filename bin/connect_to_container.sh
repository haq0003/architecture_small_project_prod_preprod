#!/bin/bash

# This function lists all running containers.
list_containers() {
    echo "Running Docker containers:"
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}" | tail -n +2 | nl
}

# This function lists all services defined in docker-compose.yml.
list_services() {
    echo "Services in docker-compose.yml:"
    docker-compose config --services | nl
}

# Optional: checks health status for a container (if healthcheck is configured).
check_health() {
    local container_name="$1"
    echo "Checking health status for $container_name..."
    while [[ "$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null)" != "healthy" ]]; do
        # If the container has no 'Health' key, skip
        if ! docker inspect "$container_name" 2>/dev/null | grep -q '"Health": {'; then
            echo "No healthcheck configuration found for $container_name. Skipping health check."
            return
        fi
        echo "The container $container_name is not healthy yet. Waiting 5 seconds..."
        sleep 5
    done
    echo "The container $container_name is healthy."
}

# Existing function that restarts a service (and its dependencies) based on docker-compose.yml.
restart_service() {
    echo "Enter the number of the service to restart (or 'cancel' to abort):"
    read service_number
    if [ "$service_number" == "cancel" ]; then
        echo "Restart aborted."
        return
    fi

    service_name=$(docker-compose config --services | sed -n "${service_number}p")

    if [ -z "$service_name" ]; then
        echo "Error: Invalid service number."
        return
    fi

    # Rechercher les dépendances via depends_on
    dependencies=$(grep -A10 "^\s*$service_name:" docker-compose.yml \
                   | grep "depends_on:" -A10 \
                   | grep -E "^\s*-\s" \
                   | sed 's/.*- //')

    if [ -n "$dependencies" ]; then
        echo "Found dependencies for $service_name:"
        echo "$dependencies"
        for dep in $dependencies; do
            echo "Recreating dependency service: $dep"
            docker-compose up -d --force-recreate "$dep"
            dep_container=$(docker ps --format "{{.Names}}" | grep "_$dep")
            [ -n "$dep_container" ] && check_health "$dep_container"
        done
    else
        echo "No 'depends_on' dependencies found for $service_name."
    fi

    echo "Recreating service: $service_name"
    docker-compose up -d --force-recreate "$service_name"
    service_container=$(docker ps --format "{{.Names}}" | grep "_$service_name")
    [ -n "$service_container" ] && check_health "$service_container"

    if [ $? -eq 0 ]; then
        echo "Service $service_name restarted successfully."
    else
        echo "Error restarting service $service_name."
    fi
}

# NEW FUNCTION: Restarts only the selected container (not the entire service).
# 1. Asks for container number.
# 2. Stops and removes the existing container.
# 3. Parses the docker-compose service name from the container name.
# 4. Recreates that single service/container from docker-compose.
restart_container() {
    echo "Enter the number of the container to restart (or 'cancel' to abort):"
    read cont_number
    if [ "$cont_number" == "cancel" ]; then
        echo "Restart aborted."
        return
    fi

    container_name=$(docker ps --format "{{.Names}}" | sed -n "${cont_number}p")
    if [ -z "$container_name" ]; then
        echo "Error: Invalid container number."
        return
    fi

    echo "Stopping container: $container_name"
    docker stop "$container_name"

    echo "Removing container: $container_name"
    docker rm "$container_name"

    # Parse out the service name from the container name (default naming: <project>_<service>_<index>)
    service_name=$(echo "$container_name" | sed -E 's/^[^_]+_([^_]+)_.*/\1/')

    if [ -z "$service_name" ]; then
        echo "Error: Could not detect the service name for container '$container_name'."
        return
    fi

    echo "Recreating container for service: $service_name"
    docker-compose up -d --force-recreate "$service_name"

    # Check health again if needed
    new_container_name=$(docker ps --format "{{.Names}}" | grep "_$service_name")
    [ -n "$new_container_name" ] && check_health "$new_container_name"
}

# Updated selection function: user can connect, restart service, restart container, or exit.
select_container() {
    echo "Enter the number of the container to connect to,"
    echo "or type 'restart-service' to restart a service (docker-compose based),"
    echo "or type 'restart-container' to restart a single container,"
    echo "or 'exit' to quit:"
    read container_number

    case "$container_number" in
        "exit")
            echo "Exiting the script."
            exit 0
            ;;
        "restart-service")
            list_services
            restart_service
            ;;
        "restart-container")
            list_containers
            restart_container
            ;;
        *)
            # Connect to a container
            container_name=$(docker ps --format "{{.Names}}" | sed -n "${container_number}p")
            if [ -n "$container_name" ]; then
                echo "Connecting to container $container_name..."
                if docker exec "$container_name" sh -c 'command -v bash' > /dev/null 2>&1; then
                    docker exec -it "$container_name" bash
                elif docker exec "$container_name" sh -c 'command -v sh' > /dev/null 2>&1; then
                    docker exec -it "$container_name" sh
                else
                    echo "Error: No compatible shell found in the container '$container_name'."
                fi
            else
                echo "Error: Invalid container number."
            fi
            ;;
    esac
}

# Main loop: display containers, then let user select an action.
while true; do
    list_containers
    select_container
done
