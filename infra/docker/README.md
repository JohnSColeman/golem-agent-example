# Golem Docker Compose Deployment Scripts

This directory contains Docker Compose configurations and automation scripts for deploying Golem using docker.

## Contents

- **docker-compose.yaml** - Main Docker Compose configuration for all Golem services
- **.env** - Environment variables for local/development deployment
- **nginx.conf.template** - Nginx configuration for routing requests
- **aws-deploy-ec2.sh** - Automated deployment script for AWS EC2
- **aws-cleanup-ec2.sh** - Cleanup script to remove AWS resources

## Quick Start (Deploy to AWS EC2)

### Prerequisites

1. **AWS Account** with EC2 access
2. **AWS CLI** installed and configured:
   ```bash
   aws configure
   ```
3. **SSH Key Pair** created in AWS EC2:
   ```bash
   # Create a key pair if you don't have one
   aws ec2 create-key-pair --key-name golem-key --query 'KeyMaterial' --output text > ~/.ssh/golem-key.pem
   chmod 400 ~/.ssh/golem-key.pem
   ```
4. **jq** installed (for JSON parsing):
   ```bash
   brew install jq  # macOS
   ```

### Deploy Golem to EC2

From this directory, run:

```bash
./aws-deploy-ec2.sh --key-name golem-key --region us-east-1
```

The script will:
1. ✅ Verify prerequisites
2. ✅ Create security group with proper rules
3. ✅ Launch EC2 instance (t3.small seems sufficient for testing)
4. ✅ Install Docker and Docker Compose
5. ✅ Deploy all Golem services
6. ✅ Verify the deployment
7. ✅ Provide access URLs and next steps

**Deployment time:** ~10-15 minutes

### Access Your Deployment

After deployment completes, you'll get:

```
Instance Details:
  Instance ID:  i-1234567890abcdef0
  Public IP:    54.123.45.67
  Region:       us-east-1

Golem Endpoints:
  Router:       http://54.123.45.67:9881
  Worker API:   http://54.123.45.67:9006
```

### Test the Deployment

To test the deployment refer to curl example in [README](../../README.md) and adjust hostname accordingly.

### Deploy Your Components

- configure the golem.yaml manifests <host> substitutions of the intest sections.
- configure the main golem.yaml manifests <ADMIN_TOKEN> substitution with the respective parameter store value*
- execute `golem deploy --environment intest` or `npm run deploy:intest`

*You may not want to commit this token value to a source repository!

## Cleanup (Deploy to AWS EC2)

When you're done, clean up all AWS resources:

```bash
# Clean up specific instance
./aws-cleanup-ec2.sh --instance-id i-1234567890abcdef0 --region us-east-1

# OR clean up all Golem instances in a region
./aws-cleanup-ec2.sh --all --region us-east-1
```

The cleanup script will:
1. Find and terminate EC2 instances
2. Delete security groups (if not in use)
3. Confirm before deletion

## Architecture

The Docker Compose stack includes:

```
┌─────────────────────────────────────────┐
│         Nginx Router (Port 9881)        │
│              Reverse Proxy              │
└─────────────────────────────────────────┘
                   │
    ┌──────────────┼──────────────┐
    │              │              │
┌───▼────┐    ┌────▼───┐    ┌─────▼────┐
│Registry│    │Worker  │    │Debugging │
│Service │    │Service │    │Service   │
└────────┘    └────┬───┘    └──────────┘
                   │
         ┌─────────┼────────┐
         │                  │
    ┌────▼────┐      ┌──────▼──────┐
    │Worker   │      │Shard        │
    │Executor │      │Manager      │
    └─────────┘      └─────────────┘
         │                  │
    ┌────▼────┐      ┌──────▼──────┐
    │Component│      │             │
    │Compile  │      │             │
    └─────────┘      │             │
                     │             │
          ┌──────────┴─────────┐   │
          │                    │   │
    ┌─────▼────┐         ┌─────▼───▼┐
    │PostgreSQL│         │   Redis  │
    │(Database)│         │  (Cache) │
    └──────────┘         └──────────┘
```

## Services

| Service | Port | Description |
|---------|------|-------------|
| **Router** | 9881 | Main entry point, reverse proxy |
| **Worker Service** | 9006 | Worker API Gateway |
| **Registry Service** | 8083 | Component registry |
| **Worker Executor** | 8082 | Executes worker instances |
| **Shard Manager** | 8081 | Manages worker shards |
| **Compilation Service** | 8084 | Compiles components |
| **Debugging Service** | 8086 | Debug support |
| **PostgreSQL** | 5432 | Database |
| **Redis** | 6379 | Cache & state |

## Security Considerations

⚠️ **Important Security Notes:**

1. **SSH Access**: The default script allows SSH from any IP (0.0.0.0/0). For production, restrict to your IP:
   ```bash
   aws ec2 authorize-security-group-ingress \
     --group-id sg-xxx \
     --protocol tcp \
     --port 22 \
     --cidr YOUR_IP/32
   ```

2. **API Access**: Golem endpoints are publicly accessible. For production:
   - Use AWS security groups to restrict access
   - Set up VPN or bastion host
   - Add authentication layer
   - Use AWS ALB with SSL/TLS

3. **Credentials**: Change default credentials for production use:

   - POSTGRES_PASSWORD

4. **Tokens**: These are in AWS Parameter Store consider using Secret Manager for stronger security.

Keep versions updated.