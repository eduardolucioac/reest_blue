#!/bin/bash

# NOTE: For some commands that hangs at its execution. By Questor
_timeout() { ( set +b; sleep "$1" & "${@:2}" & wait -n; r=$?; kill -9 `jobs -p`; exit $r; ) }

# NOTE: The script needs root credentials. By Questor
if [[ $EUID -ne 0 ]]; then
    echo " > ---------------------------------"
    echo " ERROR! You need to be root!"
    echo " < ---------------------------------"
    exit 1
fi

BT_DEVICE="01:A2:00:0D:F2:D6"
MUTE_SND_FOR_HEADSET=1
SRV_REC_STOP=10
UNBL_DEV_TIME=40
WAIT_DEV_TIME=6
TEST_INTERVAL=2
FIRST_INTERAC=1
COMMAND_VAL=""
PING_TIMEOUT=4

f_restart_dev() {
    rm -rf '/var/lib/bluetooth/*'
    echo " Restarting device..."
    echo -n " "
    for (( i=0; i<$SRV_REC_STOP; i++ )) ; do
        echo -n "."

        # NOTE: Ensure the end of the bluetooth service process. This command 
        # must be repeated until it effectively extinguishes the process as it 
        # returns. By Questor
        systemctl stop bluetooth.service

        (ps axf | egrep -i bluetoothd | grep -v grep | awk '{print "kill -9 " $1}' | sh) 2> /dev/null 1> /dev/null
        sleep 0.02
    done
    systemctl start bluetooth.service
    f_unbl_dev
}

f_unbl_dev() {
    UNBL_DEV_FAIL=1
    echo ""
    echo " Unblocking device..."
    echo -n " "
    rfkill block bluetooth
    for (( i=0; i<100; i++ )) ; do
        sleep 0.2
        echo -n "."
        if [[ "$(rfkill list)" != *" hci0: "* ]] ; then
            for (( i=0; i<$UNBL_DEV_TIME; i++ )) ; do
            # NOTE: Dá tempo para o "rfkill" antes de tentar desbloquear! 
            # By Questor
                echo -n "."
                sleep 0.2
                rfkill unblock bluetooth

                # NOTE: Checks if device responds. By Questor
                BT_STATUS_BY_SOME_DEVICE_1=$(_timeout $PING_TIMEOUT l2ping -t 2 -c 1 $BT_DEVICE 2> /dev/null)

                if [[ "$BT_STATUS_BY_SOME_DEVICE_1" == *"1 sent, 1 received, 0% loss"* ]] ; then
                    UNBL_DEV_FAIL=0
                    break
                fi
            done
            break
        fi
    done
    if [ ${UNBL_DEV_FAIL} -eq 1 ] ; then
        echo ""
        f_restart_dev
    fi
    # rfkill unblock bluetooth
    # _timeout 2 l2ping -t 2 -c 1 $BT_DEVICE 2> /dev/null 1> /dev/null
}

f_wait_dev() {
    echo ""
    echo " Waiting for device..."
    echo -n " "
    DEVICE_CONNECTED=0
    for (( i=0; i<$WAIT_DEV_TIME; i++ )) ; do
        echo -n "."
        sleep 1
        if [[ "$(journalctl -u bluetooth.service -b -n 3)" == *"Loading LTKs timed out for hci0"* ]] ; then
            INTERAC_AGAIN=1
            break
        fi
        if [[ "$(_timeout 1 bluetoothctl list)" != "" ]] ; then
            script -c "{ echo \"power on\" && sleep 10;} | bluetoothctl" -f bluetoothctl_op_a_stderr_stdout_file 2> /dev/null 1> /dev/null &
            BLUETOOTHCTL_FAIL=0
            while : ; do
                echo -n "."
                rfkill unblock bluetooth
                _timeout $PING_TIMEOUT l2ping -t 2 -c 1 $BT_DEVICE 2> /dev/null 1> /dev/null
                sleep 1
                if [[ "$(cat bluetoothctl_op_a_stderr_stdout_file)" == *"Changing power on succeeded"* ]] ; then
                    break
                elif [[ "$(cat bluetoothctl_op_a_stderr_stdout_file)" == *"Script done on"* ]] ; then

                    # NOTE: "Script done on" indica o final da execução de "script -c" 
                    # e também "falha" porque a condição anterior não foi verdadeira. 
                    # By Questor

                    # TODO: Definir outras condições de saída para tornar o 
                    # processo mais célere. By Questor

                    BLUETOOTHCTL_FAIL=1
                    break
                fi
            done
            rm -f bluetoothctl_op_a_stderr_stdout_file
            if [ ${BLUETOOTHCTL_FAIL} -eq 0 ] ; then
                script -c "{ echo \"connect $BT_DEVICE\" && sleep 10;} | bluetoothctl" -f bluetoothctl_op_b_stderr_stdout_file 2> /dev/null 1> /dev/null &
                while : ; do
                    echo -n "."
                    rfkill unblock bluetooth
                    _timeout $PING_TIMEOUT l2ping -t 2 -c 1 $BT_DEVICE 2> /dev/null 1> /dev/null
                    sleep 1
                    if [[ "$(cat bluetoothctl_op_b_stderr_stdout_file)" == *"ServicesResolved: yes"* ]] ; then
                        DEVICE_CONNECTED=1
                        if [ ${MUTE_SND_FOR_HEADSET} -eq 1 ] ; then
                            amixer set Master unmute 1> /dev/null
                        fi
                        break
                    elif [[ "$(cat bluetoothctl_op_b_stderr_stdout_file)" == *"Script done on"* ]] ; then

                        # NOTE: "Script done on" indica o final da execução de "script -c" 
                        # e também "falha" porque a condição anterior não foi verdadeira. 
                        # By Questor

                        # TODO: Definir outras condições de saída para tornar o 
                        # processo mais célere. By Questor

                        BLUETOOTHCTL_FAIL=1
                        break
                    fi
                done
                rm -f bluetoothctl_op_b_stderr_stdout_file
            fi
            if [ ${BLUETOOTHCTL_FAIL} -eq 1 ] || [ ${DEVICE_CONNECTED} -eq 1 ] ; then
                INTERAC_AGAIN=$BLUETOOTHCTL_FAIL
                break
            fi
        else
            rfkill unblock bluetooth
        fi
        if [ ${i} -eq $(($WAIT_DEV_TIME - 1)) ] ; then
            INTERAC_AGAIN=1
        fi
    done
}

while : ; do

    # NOTE: O comando "read" tem uma função "built-in" para "timeout", mas em certas 
    # circuntâncias ele está travando e por isso criamos esse esquema de "timeout" 
    # externo. By Questor
    rm -f stdout_command_val 2> /dev/null 1> /dev/null
    (
        set +b
        sleep $TEST_INTERVAL &
        {read -e -r -p "Type \"f\" to force bluetooth re-establishment or \"q\" to quit (press \"Enter\" in $TEST_INTERVAL seconds): " COMMAND_VAL && echo "$COMMAND_VAL" 1> stdout_command_val} &
        wait -n
        kill `jobs -p`)
    COMMAND_VAL=$(cat stdout_command_val 2> /dev/null)
    rm -f stdout_command_val 2> /dev/null 1> /dev/null
    if [ "$COMMAND_VAL" = "q" ] ; then
        exit 0
    elif [ "$COMMAND_VAL" == "" ] ; then
        echo ""
    fi

    # NOTE: Checks if device is connected. By Questor
    script -c "{ echo \"info $BT_DEVICE\"; } | bluetoothctl" -f bt_device_is_connected_stderr_stdout_file 2> /dev/null 1> /dev/null
    BT_DEVICE_IS_CONNECTED=$(cat bt_device_is_connected_stderr_stdout_file)
    rm -f bt_device_is_connected_stderr_stdout_file

    # NOTE: Checks the status of the bluetooth by the number of occurrences of 
    # a certain string. By Questor
    STRING=$(rfkill list)

    # NOTE: Preservar o "TAB" caractere. By Questor
    SUB_STRING="Bluetooth
	Soft blocked: no
	Hard blocked: no"

    s=${STRING//"$SUB_STRING"}
    BT_STATUS_BY_STR_QTTY="$(((${#STRING} - ${#s}) / ${#SUB_STRING}))"
    if [ "$COMMAND_VAL" = "f" ] || (
            [ ${BT_STATUS_BY_STR_QTTY} -eq 2 ] && 
            (
                [[ "$BT_DEVICE_IS_CONNECTED" == *"Connected: yes"* ]] || 
                [ ${FIRST_INTERAC} -eq 1 ]
            )); then

        # NOTE: Checks if device responds. By Questor
        BT_STATUS_BY_SOME_DEVICE=$(_timeout $PING_TIMEOUT l2ping -t 2 -c 1 $BT_DEVICE 2> /dev/null)

        if [ "$COMMAND_VAL" = "f" ] || [[ "$BT_STATUS_BY_SOME_DEVICE" != *"1 sent, 1 received, 0% loss"* ]] ; then
            COMMAND_VAL=""
            echo "%%%%%%%%%%%%"
            echo "OW SHIT MAN!"
            echo "%%%%%%%%%%%%"
            if [ ${MUTE_SND_FOR_HEADSET} -eq 1 ] ; then

              # NOTE: Prevent external sound (if you are using a headset). By Questor
              amixer set Master mute 1> /dev/null

            fi
            INTERAC_AGAIN=1

            # NOTE: Checks if the "bluetooth" ("bluedevil") is working through the 
            # "bluetoothctl list" command and through bluetooth service status. The first 
            # interaction always happens, because the bluetooth resources need to be made 
            # available again. By Questor
            while [[ "$(_timeout 1 bluetoothctl list)" == "" ]] || [[ "$(journalctl -u bluetooth.service -b -n 3)" == *"Loading LTKs timed out for hci0"* ]] || [ ${INTERAC_AGAIN} -eq 1 ] ; do
                INTERAC_AGAIN=0
                echo " > ---------------------------------"
                echo " Trying reestablish bluetooth..."
                echo " < -----------------"
                f_restart_dev
                f_wait_dev
                echo ""
                echo " < ---------------------------------"
            done

        else
            echo "############"
            echo "OK!"
            echo "############"
        fi
    else
        echo "&&&&&&&&&&&&"
        echo "DO NOT CHECK!"
        echo "&&&&&&&&&&&&"
    fi
done
FINAL_GUIDANCE=" - - UNMUTE SOUND AND ENABLE BLUETOOTH - -"
if [ ${MUTE_SND_FOR_HEADSET} -eq 0 ] ; then
    FINAL_GUIDANCE=" - - ENABLE BLUETOOTH - -"
fi
echo " > ---------------------------------"
echo " Bluetooth reestablished!

$FINAL_GUIDANCE

Thanks. By Questor =D
https://github.com/eduardolucioac"
echo " < ---------------------------------"
exit 0
