scp -i ~/.ssh/id_ed25519 -r ec2-user@108.131.14.254:~/kernel-6.1.168-custom.tar.gz ./kernel-6.1.168-custom.tar.gz
aws s3 cp s3://your-bucket-name-kernel/kernel-6.1.168-custom.tar.gz .
