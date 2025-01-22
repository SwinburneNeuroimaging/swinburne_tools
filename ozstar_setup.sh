#!/bin/bash

# See https://stackoverflow.com/a/78631033 for how to get a direct link to this script

read -p "Enter ozstar username: " OZSTAR_USER

ssh-keygen -t rsa -N "" -f $HOME/.ssh/id_rsa >/dev/null 2>&1
ssh-copy-id  -o StrictHostKeyChecking=no -i $HOME/.ssh/id_rsa "$OZSTAR_USER"@ozstar.swin.edu.au  

sudo mkdir -p /fred
sudo mkdir -p /dagg
sudo mkdir -p /home/$OZSTAR_USER
sudo chmod a+w /fred
sudo chmod -R a+w /home/$OZSTAR_USER
sudo chmod a+w /dagg
SSHFS_OPTS=allow_root,ServerAliveInterval=5,ServerAliveCountMax=3
echo connect /fred
sshfs  -o IdentityFile=$HOME/.ssh/id_rsa -o $SSHFS_OPTS $OZSTAR_USER@ozstar.swin.edu.au:/fred /fred
echo connect /dagg
sshfs  -o IdentityFile=$HOME/.ssh/id_rsa -o $SSHFS_OPTS $OZSTAR_USER@ozstar.swin.edu.au:/dagg /dagg
echo connect /home/$OZSTAR_USER
mkdir -p /home/$OZSTAR_USER
sshfs  -o IdentityFile=$HOME/.ssh/id_rsa -o $SSHFS_OPTS $OZSTAR_USER@ozstar.swin.edu.au:/home/$OZSTAR_USER /home/$OZSTAR_USER
