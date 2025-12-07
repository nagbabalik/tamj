read -p "Enter installation password: " PASS

curl -sL -H "X-Access-Key: $PASS" \
  https://jerico-secured-c3f9.mjtsystem.workers.dev -o real.sh

if grep -q "Unauthorized" real.sh; then
    echo "❌ Wrong password!"
    rm -f real.sh
    exit 1
fi

bash real.sh
