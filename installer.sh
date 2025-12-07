#!/bin/bash

echo -n "Enter installation password: "
read PASS

curl -sL -H "X-Access-Key: $PASS" \
  https://jerico-secured-c3f9.mjtsystem.workers.dev -o realinstall.sh

# Wrong pass
if grep -q "Unauthorized" realinstall.sh; then
    echo "❌ Wrong password!"
    rm -f realinstall.sh
    exit 1
fi

# Worker returned 404 HTML?
if grep -q "<html>" realinstall.sh; then
    echo "❌ Worker returned error (404/403)"
    cat realinstall.sh
    exit 1
fi

bash realinstall.sh
