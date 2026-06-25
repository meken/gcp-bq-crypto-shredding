output "dataset_id" {
  value       = google_bigquery_dataset.dataset.dataset_id
  description = "The ID of the created BigQuery dataset"
}

output "demo_instructions" {
  value       = <<-EOS
    ================================================================────────────────
                           CRYPTO-SHREDDING DEMO INSTRUCTIONS
    ================================================================────────────────
    You can demonstrate the raw-key crypto-shredding flow by running the following
    queries sequentially in the BigQuery Console:

    STEP 1: Provision unique keysets for new users present in the staging table:
    ----------------------------------------------------------------------------
    CALL `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.create_keys`();

    STEP 2: Encrypt user emails (PII) from staging and insert into target table:
    ----------------------------------------------------------------------------
    CALL `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.encrypt_and_insert`();

    STEP 3: Verify initial state (all emails decrypted successfully):
    ----------------------------------------------------------------------------
    CALL `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.lookup_user_transactions`();

    STEP 4: Crypto-shred user 9999 by deleting their key from the registry:
    ----------------------------------------------------------------------------
    CALL `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.delete_user_key`(9999);

    STEP 5: Verify shredded state (user 9999 shows 'DELETED', others decrypted):
    ----------------------------------------------------------------------------
    CALL `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.lookup_user_transactions`();
    ================================================================================
  EOS
  description = "Step-by-step SQL commands to demonstrate raw key crypto-shredding in BigQuery"
}

output "kms_key_ring_name" {
  value       = google_kms_key_ring.keyring.name
  description = "The name of the created KMS Keyring"
}

output "kms_key_name" {
  value       = google_kms_crypto_key.kek.name
  description = "The name of the created KMS CryptoKey (Master KEK)"
}

output "kms_key_uri" {
  value       = "gcp-kms://projects/${var.project_id}/locations/${var.region}/keyRings/${google_kms_key_ring.keyring.name}/cryptoKeys/${google_kms_crypto_key.kek.name}"
  description = "The fully qualified Tink KMS Key URI"
}

output "cloud_run_uri" {
  value       = google_cloud_run_v2_service.remote_function_service.uri
  description = "The base URI of the Cloud Run Remote Function"
}

output "bq_connection_service_account" {
  value       = google_bigquery_connection.cloud_run_connection.cloud_resource[0].service_account_id
  description = "The service account email used by the BigQuery connection to invoke the remote function"
}

output "kms_demo_instructions" {
  value       = <<-EOS
    ================================================================================
                     KMS-WRAPPED KEYS CRYPTO-SHREDDING DEMO INSTRUCTIONS
    ================================================================================
    The secure KMS-wrapped envelope encryption alternative is fully automated!
    During 'terraform apply', the Python + Tink code in './terraform/remote_function' 
    was automatically deployed to Cloud Run, and the BigQuery Remote Functions 
    were registered to point to it.

    You can demonstrate the KMS-wrapped crypto-shredding flow by running the following
    queries sequentially in the BigQuery Console:

    STEP 1: Provision unique KMS-wrapped keysets for new users in staging:
    ----------------------------------------------------------------------------
    CALL `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.create_keys_kms`();

    STEP 2: Encrypt user emails (PII) from staging and insert into target table:
    ----------------------------------------------------------------------------
    CALL `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.encrypt_and_insert_kms`();

    STEP 3: Verify initial state (all emails decrypted successfully via Remote Function):
    -------------------------------------------------------------------------------------
    CALL `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.lookup_user_transactions_kms`();

    STEP 4: Crypto-shred user 9999 by deleting their wrapped key from the registry:
    ------------------------------------------------------------------------------
    CALL `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.delete_user_key`(9999);

    STEP 5: Verify shredded state (user 9999 shows 'DELETED', others decrypted):
    ----------------------------------------------------------------------------
    CALL `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.lookup_user_transactions_kms`();
    ================================================================================
  EOS
  description = "Step-by-step SQL commands to demonstrate KMS-wrapped key crypto-shredding in BigQuery"
}


