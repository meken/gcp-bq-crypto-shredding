import base64
import logging
import os

import tink

from flask import Flask, request, jsonify

from tink import cleartext_keyset_handle
from tink import daead
from tink.integration import gcpkms

# Configure logging
logging.basicConfig(level=logging.INFO)

app = Flask(__name__)

# Register Tink Deterministic AEAD
daead.register()

# Cache for decrypted (unwrapped) keysets: wrapped_key_base64 -> keyset_handle
# This avoids invoking Cloud KMS decryption for every single row in a batch.
keyset_cache = {}

# Retrieve KMS Key URI from environment
KMS_KEY_URI = os.getenv("KMS_KEY_URI")
if not KMS_KEY_URI:
    logging.warning("KMS_KEY_URI environment variable is not set. Cloud KMS operations will fail if invoked.")

def get_kms_aead():
    """Returns the KMS AEAD primitive for unwrapping keysets."""
    if not KMS_KEY_URI:
        raise ValueError("KMS_KEY_URI environment variable must be configured.")
    gcp_client = gcpkms.GcpKmsClient(None, None)
    return gcp_client.get_aead(KMS_KEY_URI)

def get_unwrapped_keyset_handle(wrapped_key_base64: str):
    """
    Decrypts (unwraps) the keyset using Cloud KMS, caching the keyset handle
    for subsequent calls to maximize performance and minimize KMS costs.
    """
    if wrapped_key_base64 in keyset_cache:
        return keyset_cache[wrapped_key_base64]
    
    # Base64 decode the wrapped keyset
    wrapped_key_bytes = base64.b64decode(wrapped_key_base64)
    
    # Decrypt via KMS
    logging.info("Calling Cloud KMS to unwrap keyset...")
    kms_aead = get_kms_aead()
    cleartext_keyset_bytes = kms_aead.decrypt(wrapped_key_bytes, b"")
    
    # Load into Tink
    reader = tink.BinaryKeysetReader(cleartext_keyset_bytes)
    keyset_handle = cleartext_keyset_handle.read(reader)
    
    # Cache the keyset handle
    keyset_cache[wrapped_key_base64] = keyset_handle
    return keyset_handle

@app.route("/health", methods=["GET"])
def health():
    return "OK", 200

@app.route("/encrypt", methods=["POST"])
def encrypt_batch():
    """
    BigQuery Remote Function for batch encryption.
    Expected signature: encrypt_email_remote(wrapped_key BYTES, email STRING, user_id INT64) -> BYTES
    """
    try:
        req_data = request.get_json(silent=True)
        if not req_data or "calls" not in req_data:
            return jsonify({"errorMessage": "Invalid BigQuery Remote Function request payload"}), 400
        
        calls = req_data["calls"]
        replies = []
        
        for call in calls:
            if len(call) < 3:
                replies.append(None)
                continue
                
            wrapped_key_base64 = call[0]
            email = call[1]
            user_id = call[2]
            
            if not wrapped_key_base64 or email is None or user_id is None:
                replies.append(None)
                continue
                
            try:
                # 1. Resolve and unwrap keyset handle (utilizes local memory cache)
                keyset_handle = get_unwrapped_keyset_handle(wrapped_key_base64)
                
                # 2. Get deterministic AEAD primitive
                primitive = keyset_handle.primitive(daead.DeterministicAead)
                
                # 3. Encrypt deterministically using user_id as associated data (AAD)
                aad = str(user_id).encode("utf-8")
                ciphertext = primitive.encrypt_deterministically(email.encode("utf-8"), aad)
                
                # 4. Return as base64-encoded string (required for BYTES return type in BQ remote functions)
                replies.append(base64.b64encode(ciphertext).decode("utf-8"))
            except Exception as e:
                logging.error(f"Error encrypting record for user {user_id}: {e}")
                replies.append(None)
                
        return jsonify({"replies": replies})
        
    except Exception as e:
        logging.error(f"Exception in /encrypt: {e}")
        return jsonify({"errorMessage": str(e)}), 500

@app.route("/decrypt", methods=["POST"])
def decrypt_batch():
    """
    BigQuery Remote Function for batch decryption.
    Expected signature: decrypt_email_remote(wrapped_key BYTES, encrypted_email BYTES, user_id INT64) -> STRING
    """
    try:
        req_data = request.get_json(silent=True)
        if not req_data or "calls" not in req_data:
            return jsonify({"errorMessage": "Invalid BigQuery Remote Function request payload"}), 400
        
        calls = req_data["calls"]
        replies = []
        
        for call in calls:
            if len(call) < 3:
                replies.append(None)
                continue
                
            wrapped_key_base64 = call[0]
            encrypted_email_base64 = call[1]
            user_id = call[2]
            
            if not wrapped_key_base64 or not encrypted_email_base64 or user_id is None:
                replies.append(None)
                continue
                
            try:
                # 1. Resolve and unwrap keyset handle (utilizes local memory cache)
                keyset_handle = get_unwrapped_keyset_handle(wrapped_key_base64)
                
                # 2. Get deterministic AEAD primitive
                primitive = keyset_handle.primitive(daead.DeterministicAead)
                
                # 3. Decrypt deterministically using user_id as associated data (AAD)
                aad = str(user_id).encode("utf-8")
                ciphertext = base64.b64decode(encrypted_email_base64)
                decrypted_bytes = primitive.decrypt_deterministically(ciphertext, aad)
                
                # 4. Return decrypted string
                replies.append(decrypted_bytes.decode("utf-8"))
            except Exception as e:
                logging.error(f"Error decrypting record for user {user_id}: {e}")
                replies.append(None)
                
        return jsonify({"replies": replies})
        
    except Exception as e:
        logging.error(f"Exception in /decrypt: {e}")
        return jsonify({"errorMessage": str(e)}), 500

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
