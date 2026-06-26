# ==============================================================================
#             BQ SETUP FOR BOTH APPROACHES
# ==============================================================================

resource "google_bigquery_dataset" "dataset" {
  dataset_id                  = var.dataset_id
  friendly_name               = "Crypto Shredding Demo"
  description                 = "Dataset illustrating crypto-shredding on BigQuery using raw keys"
  location                    = var.location
  default_table_expiration_ms = null # Tables persist indefinitely for the demo
}

# 1. Key Registry Table
resource "google_bigquery_table" "user_keys" {
  dataset_id          = google_bigquery_dataset.dataset.dataset_id
  table_id            = "user_keys"
  deletion_protection = false

  schema = <<EOF
[
  {
    "name": "user_id",
    "type": "INTEGER",
    "mode": "REQUIRED",
    "description": "The unique ID of the user"
  },
  {
    "name": "user_key",
    "type": "BYTES",
    "mode": "REQUIRED",
    "description": "The cryptographically secure raw keyset for the user"
  }
]
EOF
}

# 2. Encrypted Target Table
resource "google_bigquery_table" "user_transactions" {
  dataset_id          = google_bigquery_dataset.dataset.dataset_id
  table_id            = "user_transactions"
  deletion_protection = false

  schema = <<EOF
[
  {
    "name": "transaction_id",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "The unique ID of the transaction"
  },
  {
    "name": "user_id",
    "type": "INTEGER",
    "mode": "REQUIRED",
    "description": "The unique ID of the user"
  },
  {
    "name": "transaction_timestamp",
    "type": "TIMESTAMP",
    "mode": "REQUIRED",
    "description": "Timestamp of the transaction"
  },
  {
    "name": "amount",
    "type": "NUMERIC",
    "mode": "NULLABLE",
    "description": "Transaction amount"
  },
  {
    "name": "currency",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Currency code"
  },
  {
    "name": "user_email",
    "type": "BYTES",
    "mode": "NULLABLE",
    "description": "Deterministic AEAD encrypted user email address"
  }
]
EOF
}

# 3. Unencrypted Staging Table
resource "google_bigquery_table" "staging_transactions" {
  dataset_id          = google_bigquery_dataset.dataset.dataset_id
  table_id            = "staging_transactions"
  deletion_protection = false

  schema = <<EOF
[
  {
    "name": "transaction_id",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "The unique ID of the transaction"
  },
  {
    "name": "user_id",
    "type": "INTEGER",
    "mode": "REQUIRED",
    "description": "The unique ID of the user"
  },
  {
    "name": "transaction_timestamp",
    "type": "TIMESTAMP",
    "mode": "REQUIRED",
    "description": "Timestamp of the transaction"
  },
  {
    "name": "amount",
    "type": "NUMERIC",
    "mode": "NULLABLE",
    "description": "Transaction amount"
  },
  {
    "name": "currency",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Currency code"
  },
  {
    "name": "user_email",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Unencrypted raw user email address (PII)"
  }
]
EOF
}

# ==============================================================================
#             BQ-RAW KEYS
# ==============================================================================

# Routine A: Create keysets for any user who doesn't have one
resource "google_bigquery_routine" "create_keys" {
  dataset_id      = google_bigquery_dataset.dataset.dataset_id
  routine_id      = "create_keys"
  routine_type    = "PROCEDURE"
  language        = "SQL"
  definition_body = <<-EOS
    BEGIN
      MERGE `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_keys` AS target
      USING (SELECT DISTINCT user_id FROM `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.staging_transactions`) AS source
      ON target.user_id = source.user_id
      WHEN NOT MATCHED THEN
        INSERT (user_id, user_key)
        VALUES (
          source.user_id, 
          KEYS.NEW_KEYSET('DETERMINISTIC_AEAD_AES_SIV_CMAC_256')
        );
    END
  EOS

  depends_on = [
    google_bigquery_table.user_keys,
    google_bigquery_table.staging_transactions
  ]
}

# Routine B: Encrypt and insert from staging to target
resource "google_bigquery_routine" "encrypt_and_insert" {
  dataset_id      = google_bigquery_dataset.dataset.dataset_id
  routine_id      = "encrypt_and_insert"
  routine_type    = "PROCEDURE"
  language        = "SQL"
  definition_body = <<-EOS
    BEGIN
      INSERT INTO `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_transactions` (
        transaction_id,
        user_id,
        transaction_timestamp,
        amount,
        currency,
        user_email
      )
      SELECT
        s.transaction_id,
        s.user_id,
        s.transaction_timestamp,
        s.amount,
        s.currency,
        DETERMINISTIC_ENCRYPT(k.user_key, s.user_email, CAST(s.user_id AS STRING)) AS user_email
      FROM `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.staging_transactions` AS s
      JOIN `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_keys` AS k
      ON s.user_id = k.user_id;
    END
  EOS

  depends_on = [
    google_bigquery_table.user_transactions,
    google_bigquery_table.user_keys,
    google_bigquery_table.staging_transactions
  ]
}

# Routine C: Delete a user's keyset (Crypto-shredding)
resource "google_bigquery_routine" "delete_user_key" {
  dataset_id      = google_bigquery_dataset.dataset.dataset_id
  routine_id      = "delete_user_key"
  routine_type    = "PROCEDURE"
  language        = "SQL"
  definition_body = <<-EOS
    BEGIN
      DELETE FROM `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_keys`
      WHERE user_id = target_user_id;
    END
  EOS

  arguments {
    name          = "target_user_id"
    argument_kind = "FIXED_TYPE"
    mode          = "IN"
    data_type     = jsonencode({ "typeKind" : "INT64" })
  }

  depends_on = [
    google_bigquery_table.user_keys
  ]
}

# Routine D: Look up user details, decrypt them and show DELETED if the key doesn't exist
resource "google_bigquery_routine" "lookup_user_transactions" {
  dataset_id      = google_bigquery_dataset.dataset.dataset_id
  routine_id      = "lookup_user_transactions"
  routine_type    = "PROCEDURE"
  language        = "SQL"
  definition_body = <<-EOS
    BEGIN
      SELECT
        t.transaction_id,
        t.user_id,
        t.transaction_timestamp,
        t.amount,
        t.currency,
        CASE
          WHEN t.user_email IS NULL THEN NULL
          WHEN k.user_key IS NULL THEN 'DELETED'
          ELSE DETERMINISTIC_DECRYPT_STRING(k.user_key, t.user_email, CAST(t.user_id AS STRING))
        END AS decrypted_email
      FROM `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_transactions` AS t
      LEFT JOIN `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_keys` AS k
      ON t.user_id = k.user_id;
    END
  EOS

  depends_on = [
    google_bigquery_table.user_transactions,
    google_bigquery_table.user_keys
  ]
}


# Populate staging table with random but deterministic demo records
resource "google_bigquery_job" "populate_staging" {
  job_id   = "job_populate_staging${formatdate("YYYYMMDDhhmmssZ", timestamp())}"
  location = var.location

  query {
    query = templatefile("${path.module}/populate_staging.sql", {
      project_id = var.project_id
      dataset_id = google_bigquery_dataset.dataset.dataset_id
    })
    use_legacy_sql     = false
    create_disposition = ""
    write_disposition  = ""
  }

  depends_on = [
    google_bigquery_table.staging_transactions
  ]
}

# ==============================================================================
#             KMS-WRAPPED KEYS
# ==============================================================================

# Random suffix to prevent global naming collisions on Keyrings
resource "random_id" "kms_suffix" {
  byte_length = 4
}

# 1. Cloud KMS Keyring
resource "google_kms_key_ring" "keyring" {
  name     = "crypto-shredding-keyring-${random_id.kms_suffix.hex}"
  location = lower(var.location)
}

# 2. Cloud KMS CryptoKey (Master Key Encryption Key - KEK)
resource "google_kms_crypto_key" "kek" {
  name            = "crypto-shredding-kek"
  key_ring        = google_kms_key_ring.keyring.id
  # rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = false
  }
}

# 3. Dedicated Service Account for Cloud Run Remote Function
resource "google_service_account" "cloud_run_sa" {
  account_id   = "sa-bq-crypto-shredding"
  display_name = "BigQuery Remote Function Service Account"
}

# 4. Grant Cloud Run Service Account access to use the KMS KEK for unwrapping/wrapping
resource "google_kms_crypto_key_iam_member" "kms_decrypt" {
  crypto_key_id = google_kms_crypto_key.kek.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# 5. Native Code Packaging Tracker (Senses when code changes are made to trigger a rebuild)
data "archive_file" "remote_function_zip" {
  type        = "zip"
  source_dir  = "${path.module}/remote_function"
  output_path = "${path.module}/remote_function.zip"
}

# 6. Cloud Run Service (Houses the Remote Function API)
# We deploy a standard placeholder first to ensure Terraform applies successfully
# without requiring pre-existing images. The local-exec deployer then builds/updates the code.
resource "google_cloud_run_v2_service" "remote_function_service" {
  name     = "bq-crypto-shredding-rf"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account = google_service_account.cloud_run_sa.email

    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello:latest"

      env {
        name  = "KMS_KEY_URI"
        value = "gcp-kms://projects/${var.project_id}/locations/${lower(var.location)}/keyRings/${google_kms_key_ring.keyring.name}/cryptoKeys/${google_kms_crypto_key.kek.name}"
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image # Allow local-exec to update the image without TF resetting it
    ]
  }
}

# 7. Automated Source Deployment Trigger
# Automatically packages, compiles, and deploys the Cloud Run code using 'gcloud run deploy'
# whenever any local file inside the 'remote_function' directory is modified.
resource "terraform_data" "deploy_code" {
  triggers_replace = [
    data.archive_file.remote_function_zip.output_md5
  ]

  provisioner "local-exec" {
    command = <<EOT
      gcloud run deploy bq-crypto-shredding-rf \
        --source ${path.module}/remote_function \
        --region=${var.region} \
        --project=${var.project_id} \
        --no-allow-unauthenticated \
        --quiet
    EOT
  }

  depends_on = [
    google_cloud_run_v2_service.remote_function_service
  ]
}




# 8. BigQuery Connection (Bridges BQ to Cloud Run)
resource "google_bigquery_connection" "cloud_run_connection" {
  connection_id = "cloud_run_connection"
  location      = var.location
  friendly_name = "Cloud Run Remote Function Connection"
  description   = "Allows BigQuery to safely invoke Cloud Run Remote Functions"
  cloud_resource {}
}

# 9. Grant the BigQuery Connection SA invoker rights on the Cloud Run Remote Function
resource "google_cloud_run_v2_service_iam_member" "connection_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.remote_function_service.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_bigquery_connection.cloud_run_connection.cloud_resource[0].service_account_id}"
}

# 10. BigQuery Scalar Remote Function: Generic String Encryption
resource "google_bigquery_routine" "encrypt_string_remote" {
  dataset_id   = google_bigquery_dataset.dataset.dataset_id
  routine_id   = "encrypt_string_remote"
  routine_type = "SCALAR_FUNCTION"

  arguments {
    name      = "wrapped_key"
    data_type = jsonencode({ "typeKind" : "BYTES" })
  }
  arguments {
    name      = "plaintext"
    data_type = jsonencode({ "typeKind" : "STRING" })
  }
  arguments {
    name      = "user_id"
    data_type = jsonencode({ "typeKind" : "INT64" })
  }

  return_type = jsonencode({ "typeKind" : "BYTES" })

  definition_body = ""

  remote_function_options {
    endpoint             = "${google_cloud_run_v2_service.remote_function_service.uri}/encrypt"
    connection           = google_bigquery_connection.cloud_run_connection.id
    max_batching_rows    = "1000"
    user_defined_context = {}
  }

  depends_on = [
    google_bigquery_connection.cloud_run_connection,
    terraform_data.deploy_code
  ]
}

# 11. BigQuery Scalar Remote Function: Generic String Decryption
resource "google_bigquery_routine" "decrypt_string_remote" {
  dataset_id   = google_bigquery_dataset.dataset.dataset_id
  routine_id   = "decrypt_string_remote"
  routine_type = "SCALAR_FUNCTION"

  arguments {
    name      = "wrapped_key"
    data_type = jsonencode({ "typeKind" : "BYTES" })
  }
  arguments {
    name      = "ciphertext"
    data_type = jsonencode({ "typeKind" : "BYTES" })
  }
  arguments {
    name      = "user_id"
    data_type = jsonencode({ "typeKind" : "INT64" })
  }

  return_type = jsonencode({ "typeKind" : "STRING" })

  definition_body = ""

  remote_function_options {
    endpoint             = "${google_cloud_run_v2_service.remote_function_service.uri}/decrypt"
    connection           = google_bigquery_connection.cloud_run_connection.id
    max_batching_rows    = "1000"
    user_defined_context = {}
  }

  depends_on = [
    google_bigquery_connection.cloud_run_connection,
    terraform_data.deploy_code
  ]
}

# 12. Stored Procedure: KMS-wrapped Key Creation
resource "google_bigquery_routine" "create_keys_kms" {
  dataset_id      = google_bigquery_dataset.dataset.dataset_id
  routine_id      = "create_keys_kms"
  routine_type    = "PROCEDURE"
  language        = "SQL"
  definition_body = <<-EOS
    BEGIN
      MERGE `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_keys` AS target
      USING (SELECT DISTINCT user_id FROM `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.staging_transactions`) AS source
      ON target.user_id = source.user_id
      WHEN NOT MATCHED THEN
        INSERT (user_id, user_key)
        VALUES (
          source.user_id, 
          KEYS.NEW_WRAPPED_KEYSET(
            'gcp-kms://projects/${var.project_id}/locations/${lower(var.location)}/keyRings/${google_kms_key_ring.keyring.name}/cryptoKeys/${google_kms_crypto_key.kek.name}',
            'DETERMINISTIC_AEAD_AES_SIV_CMAC_256'
          )
        );
    END
  EOS

  depends_on = [
    google_bigquery_table.user_keys,
    google_bigquery_table.staging_transactions,
    google_kms_crypto_key.kek
  ]
}

# 13. Stored Procedure: KMS-wrapped Batch Encryption
resource "google_bigquery_routine" "encrypt_and_insert_kms" {
  dataset_id      = google_bigquery_dataset.dataset.dataset_id
  routine_id      = "encrypt_and_insert_kms"
  routine_type    = "PROCEDURE"
  language        = "SQL"
  definition_body = <<-EOS
    BEGIN
      INSERT INTO `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_transactions` (
        transaction_id,
        user_id,
        transaction_timestamp,
        amount,
        currency,
        user_email
      )
      SELECT
        s.transaction_id,
        s.user_id,
        s.transaction_timestamp,
        s.amount,
        s.currency,
        -- Call our Cloud Run Remote Function to encrypt using the wrapped keyset
        `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.encrypt_string_remote`(k.user_key, s.user_email, s.user_id) AS user_email
      FROM `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.staging_transactions` AS s
      JOIN `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_keys` AS k
      ON s.user_id = k.user_id;
    END
  EOS

  depends_on = [
    google_bigquery_table.user_transactions,
    google_bigquery_table.user_keys,
    google_bigquery_table.staging_transactions,
    google_bigquery_routine.encrypt_string_remote,
    google_bigquery_routine.create_keys_kms
  ]
}

# 14. Stored Procedure: KMS-wrapped Batch Decryption
resource "google_bigquery_routine" "lookup_user_transactions_kms" {
  dataset_id      = google_bigquery_dataset.dataset.dataset_id
  routine_id      = "lookup_user_transactions_kms"
  routine_type    = "PROCEDURE"
  language        = "SQL"
  definition_body = <<-EOS
    BEGIN
      SELECT
        t.transaction_id,
        t.user_id,
        t.transaction_timestamp,
        t.amount,
        t.currency,
        CASE
          WHEN t.user_email IS NULL THEN NULL
          -- If the key in the registry is deleted, the user has been crypto-shredded
          WHEN k.user_key IS NULL THEN 'DELETED'
          -- Otherwise, invoke the remote function to unwrap keyset and decrypt
          ELSE `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.decrypt_string_remote`(k.user_key, t.user_email, t.user_id)
        END AS decrypted_email
      FROM `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_transactions` AS t
      LEFT JOIN `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_keys` AS k
      ON t.user_id = k.user_id;
    END
  EOS

  depends_on = [
    google_bigquery_table.user_transactions,
    google_bigquery_table.user_keys,
    google_bigquery_routine.decrypt_string_remote
  ]
}



