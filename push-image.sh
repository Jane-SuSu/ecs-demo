service=$1
dockerfile=Dockerfile.$service

account_id=$(aws sts get-caller-identity --output=json | jq -r '.Account')
region=$AWS_DEFAULT_REGION
registry="$account_id.dkr.ecr.$region.amazonaws.com"
repository=ecs-demo/$service
# tag=$(date +"%Y%m%d%H%M%S")
tag=latest

echo "Registry: $registry"
echo "Dockerfile: $dockerfile"
echo "Tag: $tag"

aws ecr get-login-password | docker login --username AWS --password-stdin $registry
docker buildx build --platform linux/amd64 -f $dockerfile -t $registry/$repository:$tag .
docker push $registry/$repository:$tag

if [ $? -ne 0 ]; then
  echo "Error: Failed to update image."
  exit 1
fi
