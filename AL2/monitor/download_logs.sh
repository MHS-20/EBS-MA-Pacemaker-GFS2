scp -i ~/.ssh/id_ed25519 -r ec2-user@54.216.88.11:/var/log/fence_test_*/ ./fence_test_logs/
scp -i ~/.ssh/id_ed25519 -r ec2-user@54.216.88.11:/var/log/fence_postmortem_*/ ./fence_postmortem_logs/
scp -i ~/.ssh/id_ed25519 -r ec2-user@54.216.88.11:/var/log/rejoin_*/ ./rejoin_logs/
scp -i ~/.ssh/id_ed25519 -r ec2-user@54.216.88.11:/var/log/rejoin_postmortem_*/ ./rejoin_postmortem_logs/