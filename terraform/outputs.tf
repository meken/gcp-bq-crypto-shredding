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
