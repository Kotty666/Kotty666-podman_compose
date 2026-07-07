# frozen_string_literal: true

require 'spec_helper'

describe 'podman_compose::autoscale' do
  let(:title) { 'api' }
  let(:pre_condition) { 'include podman_compose' }

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'rootful, basic' do
        let(:params) do
          {
            'rootless'     => false,
            'service'      => 'api',
            'min_replicas' => 2,
            'max_replicas' => 6,
          }
        end

        it { is_expected.to compile.with_all_deps }

        it 'deploys the autoscaler script into the project dir' do
          is_expected.to contain_file('/opt/compose/api/.puppet-autoscale-api.py')
            .with_content(%r{SERVICE = "api"})
            .with_content(%r{MIN_R = 2})
            .with_content(%r{MAX_R = 6})
        end

        it 'runs the script as a long-running systemd service' do
          is_expected.to contain_file('/etc/systemd/system/podman-compose-autoscale-api.service')
            .with_content(%r{Type=simple})
            .with_content(%r{Restart=always})
            .with_content(%r{ExecStart=/usr/bin/python3 /opt/compose/api/\.puppet-autoscale-api\.py})
        end

        it 'keeps the service running and restarts it on script change' do
          is_expected.to contain_service('podman-compose-autoscale-api')
            .with_ensure('running')
            .with_enable(true)
          is_expected.to contain_service('podman-compose-autoscale-api')
            .that_subscribes_to('File[/opt/compose/api/.puppet-autoscale-api.py]')
        end
      end

      context 'rootless requires user' do
        let(:params) { { 'rootless' => true, 'service' => 'api' } }

        it { is_expected.to compile.and_raise_error(%r{'user' is required when rootless}) }
      end

      context 'rootless' do
        let(:params) do
          { 'rootless' => true, 'user' => 'api', 'service' => 'api' }
        end

        it { is_expected.to compile.with_all_deps }

        it 'writes a systemd user unit and enables it' do
          is_expected.to contain_file('/home/api/.config/systemd/user/podman-compose-autoscale-api.service')
          is_expected.to contain_exec('autoscale-user-enable-api')
        end

        it 'derives the compose dir under the user home' do
          is_expected.to contain_file('/home/api/compose/api/.puppet-autoscale-api.py')
        end
      end

      context 'validation' do
        context 'cpu band' do
          let(:params) do
            { 'rootless' => false, 'service' => 'api', 'cpu_low' => 80, 'cpu_high' => 70 }
          end

          it { is_expected.to compile.and_raise_error(%r{cpu_low .* must be < cpu_high}) }
        end

        context 'min > max' do
          let(:params) do
            { 'rootless' => false, 'service' => 'api', 'min_replicas' => 9, 'max_replicas' => 3 }
          end

          it { is_expected.to compile.and_raise_error(%r{min_replicas .* must be <= max_replicas}) }
        end
      end

      context 'ensure => absent (rootful)' do
        let(:params) { { 'rootless' => false, 'service' => 'api', 'ensure' => 'absent' } }

        it { is_expected.to compile.with_all_deps }

        it 'stops the service and removes unit + script' do
          is_expected.to contain_service('podman-compose-autoscale-api').with_ensure('stopped')
          is_expected.to contain_file('/etc/systemd/system/podman-compose-autoscale-api.service').with_ensure('absent')
          is_expected.to contain_file('/opt/compose/api/.puppet-autoscale-api.py').with_ensure('absent')
        end
      end
    end
  end
end
