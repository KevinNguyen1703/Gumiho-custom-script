#!/bin/bash

# Variables
ASG_NAME="your-asg-name"
DESIRED_CAPACITY=2  # Scale up to 2 instances (adjust as needed)
ROUTE53_ZONE_ID="your-route53-zone-id"
DNS_NAME="your-domain.com"
TARGET_RECORD="A"
TIMEOUT=600  # Time to wait for instance (in seconds)
INTERVAL=10  # Interval to check instance status (in seconds)

# Function to get instance ID of the new instance
get_new_instance_id() {
    aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG_NAME \
        --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].[InstanceId]" \
        --output text | tail -n 1
}

# Scale up ASG
echo "Scaling up ASG..."
aws autoscaling update-auto-scaling-group --auto-scaling-group-name $ASG_NAME --desired-capacity $DESIRED_CAPACITY

# Wait for the new instance to be launched and InService
echo "Waiting for new instance to launch..."
INSTANCE_ID=""
START_TIME=$(date +%s)

while [[ -z "$INSTANCE_ID" && $(($(date +%s) - START_TIME)) -lt $TIMEOUT ]]; do
    INSTANCE_ID=$(get_new_instance_id)
    if [[ -n "$INSTANCE_ID" ]]; then
        echo "New instance launched: $INSTANCE_ID"
    else
        echo "Waiting for instance to be ready..."
        sleep $INTERVAL
    fi
done

if [[ -z "$INSTANCE_ID" ]]; then
    echo "Error: Timed out waiting for new instance"
    exit 1
fi

# Wait for userdata to complete (assuming userdata completion sets an EC2 tag or status)
echo "Waiting for userdata script to complete..."
while [[ $(aws ec2 describe-instance-status --instance-id $INSTANCE_ID --query 'InstanceStatuses[0].InstanceStatus.Status' --output text) != "ok" ]]; do
    echo "Waiting for userdata script to complete on instance $INSTANCE_ID..."
    sleep $INTERVAL
done

echo "Userdata script completed successfully on instance $INSTANCE_ID"

# Get public IP of the new instance
NEW_INSTANCE_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
if [[ -z "$NEW_INSTANCE_IP" ]]; then
    echo "Error: Could not retrieve public IP of new instance"
    exit 1
fi

# Update Route 53 to point to the new instance
echo "Updating Route 53 to point to new instance IP: $NEW_INSTANCE_IP"
aws route53 change-resource-record-sets --hosted-zone-id $ROUTE53_ZONE_ID --change-batch '{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "'"$DNS_NAME"'",
        "Type": "'"$TARGET_RECORD"'",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "'"$NEW_INSTANCE_IP"'"
          }
        ]
      }
    }
  ]
}'

# Scale down ASG
echo "Scaling down ASG..."
aws autoscaling update-auto-scaling-group --auto-scaling-group-name $ASG_NAME --desired-capacity 1

echo "Done. ASG scaled down and Route 53 updated to point to new instance: $NEW_INSTANCE_IP"
