#!/bin/sh

# Docker entry ppoint script for Onyxnet CC v1

# tail -f /etc/hosts

echo ""
echo "#############################"
echo "# Starting Onyxnet CC ...   #"
echo "#############################"
node ./bin/onyxnet

node_exit=$?

if [ ${node_exit} -gt 0 ]; then
    info "Application failed! Please inspect cc-build.log / cc-ui-build.log and the application error above."
fi

# end
