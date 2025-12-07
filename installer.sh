read -p "Enter installation password: " PASS

curl -sL -H "X-Access-Key: $PASS" \
  https://jerico-secured-c3f9.mjtsystem.workers.dev -o install

if grep -q "Unauthorized" install; then
    echo "❌ Wrong password!"
    rm -f install
    exit 1
fi

bash install
