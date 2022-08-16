if [ $# -lt 1 ]; then
    echo connect_ozstar_user: ERROR: must provide OzStar username as argument!   
else
        
        # create mount point if not exist
        if [ ! -d "/fred" ]
        then
            sudo mkdir /fred
        fi
        if [ ! -d "/dagg" ]
        then
            sudo mkdir /dagg
        fi
 
        # change permission of mount points, to give permission to mount
        sudo chmod a+w /fred
        sudo chmod a+w /home
        sudo chmod a+w /dagg
        sudo chmod a+w /neurodesktop-storage/
        
        # make sure that mount points will be binded to singularity containers
        echo 'export SINGULARITY_BINDPATH=${SINGULARITY_BINDPATH},/fred,/home,/dagg' >> $HOME/.bashrc
        
        # set optimal connection parameters
        export SSHFS_OPTS=allow_root,ServerAliveInterval=5,ServerAliveCountMax=3

        # use OzStar rather than farnarkle1.hpc.swin.edu.au or farnarkle2.hpc.swin.edu.au because sometimes one of them is blocked for logins
        export SERVER=ozstar.swin.edu.au

	echo
        echo '=================='
        echo 'IMPORTANT NOTE:'
        echo 'If you are prompted to enter your password three times in a row without any text printed in between, i.e.:'
        echo '  '${1}'@'${SERVER}\''s password:'
        echo '  '${1}'@'${SERVER}\''s password:'
	      echo '  '${1}'@'${SERVER}\''s password:'
        echo 'it indicates one of two things:'
        echo '  1) the username provided in the command-line ('${1}') was incorrect. Please close this terminal, open a new one, and run the command with the correct username.'
        echo '  2) the first two passwords entered were incorrect. Please double-check your password before trying for the 3rd time.'
        echo 'Notice that a third failure will block access from this desktop to OzStar for 24 hours. When trying to connect, OzStar will display the error message "read: Connection reset by peer".'
        echo 'If you must gain access urgently, please contact OzStar support (hpc-support@swin.edu.au) with your username, and notify them you are blocked'
	echo 'For further assistance, you may also contact Swinburne Neuroimaging informatics fellow (ocivier@swin.edu.au)'
        echo '=================='
	echo

        mkdir -p /home/$1
        for dir in /fred /dagg /home/$1
        do
                echo
                mountpoint $dir > /dev/null
                # the above returns 1 if the directory is not mounted
                if [ $? -eq 1 ]
                then
                        echo mapping $dir to $dir on OzStar -
                        sshfs -o $SSHFS_OPTS $1@$SERVER:$dir $dir && (echo SUCCESS!)
                else
                        echo $dir is already mapped to OzStar with these details:; mount | grep ".* on $dir"
                fi
        done
fi
