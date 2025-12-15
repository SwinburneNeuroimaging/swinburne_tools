#!/bin/bash

# See https://stackoverflow.com/a/78631033 for how to get a direct link to this script (change 'blob' in url to 'raw')

read -p "Enter ozstar username: " OZSTAR_USER

ssh-keygen -t rsa -N "" -f $HOME/.ssh/id_rsa <<<y >/dev/null 2>&1
ssh-copy-id  -o LogLevel=QUIET -o StrictHostKeyChecking=no -i $HOME/.ssh/id_rsa "$OZSTAR_USER"@ozstar.swin.edu.au  |& grep -v -e '^$' -e 'INFO'  |& grep -v -e '^$' -e 'logging' |& grep -v -e '^$' -e 'check'

if ! mountpoint -q /fred; then
    sudo mkdir -p /fred
    sudo chmod a+w /fred
fi
if ! mountpoint -q /dagg; then
    sudo mkdir -p /dagg
    sudo chmod a+w /dagg
fi
if ! mountpoint -q /home/$OZSTAR_USER; then
    sudo mkdir -p /home/$OZSTAR_USER
    sudo chmod -R a+w /home/$OZSTAR_USER
fi

SSHFS_OPTS=allow_root,ServerAliveInterval=5,ServerAliveCountMax=3

mkdir -p /home/vdiuser/.local/bin
echo "#!/bin/bash

if ! mountpoint -q /fred; then
    echo connecting /fred
    sshfs  -o IdentityFile=$HOME/.ssh/id_rsa -o $SSHFS_OPTS $OZSTAR_USER@ozstar.swin.edu.au:/fred /fred
else
    echo /fred already connected
fi
if ! mountpoint -q /dagg; then
    echo connecting /dagg
    sshfs  -o IdentityFile=$HOME/.ssh/id_rsa -o $SSHFS_OPTS $OZSTAR_USER@ozstar.swin.edu.au:/dagg /dagg
else
    echo /dagg already connected
fi
if ! mountpoint -q /home/$OZSTAR_USER; then
    echo connecting /home/$OZSTAR_USER
    sshfs  -o IdentityFile=$HOME/.ssh/id_rsa -o $SSHFS_OPTS $OZSTAR_USER@ozstar.swin.edu.au:/home/$OZSTAR_USER /home/$OZSTAR_USER
else
    echo /home/$OZSTAR_USER already connected
fi
" > /home/vdiuser/.local/bin/reconnect_ozstar

chmod u+x /home/vdiuser/.local/bin/reconnect_ozstar

echo 'export PATH=$PATH:$HOME/.local/bin' >> $HOME/.bashrc

/home/vdiuser/.local/bin/reconnect_ozstar
